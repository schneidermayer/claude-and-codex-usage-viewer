import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

/// Claude Code owns browser sign-in, token renewal, and credential storage.
/// Account operations use an app-owned CLAUDE_CONFIG_DIR. Local identity uses only auth status.
@MainActor
final class ClaudeConnection: CodexAccountConnection {
    private let accountID: String
    private let executableURL: URL
    private let accountRoot: URL
    private let requestTimeout: TimeInterval
    private let loginTimeout: TimeInterval
    private let loadCredential: ((URL) async throws -> ClaudeOAuthCredential?)?
    private let fetchUsage: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    private let localConfigDirectory: URL?
    private var processes: [UUID: ClaudeProcess] = [:]
    private var loginProcess: ClaudeProcess?
    private var loginID: String?
    private var loginState: String?
    private var loginCodeSubmitted = false
    private var generation = UUID()

    nonisolated static var accountRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexUsageViewer/ClaudeAccounts", isDirectory: true)
    }

    init(accountID: String, executableURL: URL, accountRoot: URL = ClaudeConnection.accountRoot,
         requestTimeout: TimeInterval = 30, loginTimeout: TimeInterval = 900,
         loadCredential: ((URL) async throws -> ClaudeOAuthCredential?)? = nil,
         fetchUsage: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.accountID = accountID
        self.executableURL = executableURL
        self.accountRoot = accountRoot
        self.requestTimeout = requestTimeout
        self.loginTimeout = loginTimeout
        self.loadCredential = loadCredential
        self.fetchUsage = fetchUsage
        self.localConfigDirectory = nil
    }

    private init(localIdentityExecutable: URL, configDirectory: URL, requestTimeout: TimeInterval) {
        accountID = "local-identity"
        executableURL = localIdentityExecutable
        accountRoot = configDirectory
        self.requestTimeout = requestTimeout
        loginTimeout = 0
        loadCredential = nil
        fetchUsage = nil
        localConfigDirectory = configDirectory
    }

    /// Ask the CLI for its default identity; never read or renew its credentials ourselves.
    static func readLocalIdentity(executableURL: URL, configDirectory: URL? = nil,
                                  requestTimeout: TimeInterval = 10) async throws -> CodexIdentity? {
        let directory = configDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let connection = ClaudeConnection(localIdentityExecutable: executableURL, configDirectory: directory,
                                          requestTimeout: requestTimeout)
        defer { connection.stop() }
        return try await connection.account()
    }

    func account() async throws -> CodexIdentity? {
        let directory = try localConfigDirectory ?? prepareDirectory()
        let result = try await run(["auth", "status", "--json"])
        return try Self.identity(from: result.data, expectedDirectory: directory, exitCode: result.status)
    }

    static func identity(from data: Data, expectedDirectory: URL, exitCode: Int32) throws -> CodexIdentity? {
        struct Status: Decodable {
            let loggedIn: Bool
            let authMethod: String
            let email: String?
            let subscriptionType: String?
            let configDirectory: String?
        }
        guard data.count <= 1_048_576, let status = try? JSONDecoder().decode(Status.self, from: data) else {
            throw ClaudeConnectionError.invalidResponse
        }
        // v2.1.268+ reports the directory. Refuse older versions rather than risk a shared account.
        guard let reported = status.configDirectory,
              URL(fileURLWithPath: reported).standardizedFileURL.resolvingSymlinksInPath() == expectedDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ClaudeConnectionError.outdatedCLI
        }
        guard status.loggedIn else { return nil }
        guard exitCode == 0, status.authMethod == "claude.ai" else { throw ClaudeConnectionError.subscriptionRequired }
        guard let email = status.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            throw ClaudeConnectionError.invalidResponse
        }
        return CodexIdentity(email: email, planType: status.subscriptionType, type: "claude")
    }

    func readLimits() async throws -> RateLimitsResponse {
        guard localConfigDirectory == nil else { throw ClaudeConnectionError.readOnly }
        let attempt = generation
        let directory = try prepareDirectory()
        guard var credential = try await credential(in: directory) else { throw ClaudeConnectionError.signInRequired }
        if credential.expiresAt.map({ $0 <= Date().addingTimeInterval(60) }) ?? true {
            credential = try await renew(credential, directory: directory)
        }
        try ensureCurrent(attempt)
        let (data, response) = try await usageRequest(token: credential.accessToken)
        try ensureCurrent(attempt)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 { throw ClaudeConnectionError.signInRequired }
            throw ClaudeConnectionError.http(response.statusCode)
        }
        return try ClaudeUsageParser.parse(data)
    }

    private func renew(_ credential: ClaudeOAuthCredential, directory: URL) async throws -> ClaudeOAuthCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty, !credential.scopes.isEmpty else {
            throw ClaudeConnectionError.signInRequired
        }
        // A CLI-supported refresh never opens a browser. Secrets remain in child memory, never argv or logs.
        let result = try await run(["auth", "login", "--claudeai"], extraEnvironment: [
            "CLAUDE_CODE_OAUTH_REFRESH_TOKEN": refreshToken,
            "CLAUDE_CODE_OAUTH_SCOPES": credential.scopes.joined(separator: " ")
        ])
        guard result.status == 0, let renewed = try await self.credential(in: directory),
              let expiry = renewed.expiresAt, expiry > Date() else { throw ClaudeConnectionError.signInRequired }
        return renewed
    }

    func beginLogin() async throws -> CodexLogin {
        guard localConfigDirectory == nil else { throw ClaudeConnectionError.readOnly }
        guard loginProcess == nil else { throw ClaudeConnectionError.loginInProgress }
        // Verify directory isolation before allowing the CLI to write any credentials.
        _ = try await account()
        let process = try start(["auth", "login", "--claudeai"])
        loginProcess = process
        let id = UUID().uuidString
        loginID = id
        loginState = nil
        loginCodeSubmitted = false
        let deadline = Date().addingTimeInterval(requestTimeout)
        do {
            while Date() < deadline {
                try Task.checkCancellation()
                guard loginID == id else { throw ClaudeConnectionError.stopped }
                if let url = Self.loginURL(in: process.data) {
                    return try preparedLogin(id: id, url: url)
                }
                if process.overflow { throw ClaudeConnectionError.invalidResponse }
                if !process.process.isRunning {
                    try await Task.sleep(for: .milliseconds(50))
                    if let url = Self.loginURL(in: process.data) { return try preparedLogin(id: id, url: url) }
                    throw ClaudeConnectionError.loginFailed
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw ClaudeConnectionError.timedOut
        } catch {
            cleanup(process)
            loginProcess = nil
            loginID = nil
            loginState = nil
            loginCodeSubmitted = false
            throw error
        }
    }

    private func preparedLogin(id: String, url: URL) throws -> CodexLogin {
        guard let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "state" })?.value, !state.isEmpty else { throw ClaudeConnectionError.invalidResponse }
        loginState = state
        return CodexLogin(loginId: id, authURL: url)
    }

    /// Send the one-time browser code only to this attempt's CLI stdin; never persist or echo it.
    func submitLoginCode(code: String, loginID: String) async throws {
        try Task.checkCancellation()
        guard self.loginID == loginID, let process = loginProcess, processes[process.id] != nil,
              process.process.isRunning, let expectedState = loginState else { throw ClaudeConnectionError.stopped }
        guard !loginCodeSubmitted else { throw ClaudeConnectionError.loginCodeAlreadySubmitted }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "#", omittingEmptySubsequences: false)
        guard value.utf8.count <= 8_192, parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw ClaudeConnectionError.invalidLoginCode
        }
        guard parts[1] == expectedState else { throw ClaudeConnectionError.loginCodeMismatch }
        do { try process.input.write(contentsOf: Data((value + "\n").utf8)) }
        catch { throw ClaudeConnectionError.stopped }
        loginCodeSubmitted = true
    }

    func waitForLogin(loginID: String) async throws {
        guard self.loginID == loginID, let process = loginProcess else { throw ClaudeConnectionError.stopped }
        defer {
            cleanup(process)
            if self.loginID == loginID {
                self.loginProcess = nil; self.loginID = nil; self.loginState = nil; self.loginCodeSubmitted = false
            }
        }
        let result = try await wait(process, timeout: loginTimeout)
        guard result.status == 0 else { throw ClaudeConnectionError.loginFailed }
    }

    func cancelLogin(loginID: String) async {
        guard self.loginID == loginID else { return }
        if let process = loginProcess { cleanup(process) }
        loginProcess = nil
        self.loginID = nil
        loginState = nil
        loginCodeSubmitted = false
    }

    func disconnect() async throws {
        guard localConfigDirectory == nil else { throw ClaudeConnectionError.readOnly }
        if let loginID { await cancelLogin(loginID: loginID) }
        // Directory validation is also enforced before logout, so default credentials cannot be changed.
        _ = try await account()
        let result = try await run(["auth", "logout"])
        guard result.status == 0 else { throw ClaudeConnectionError.logoutFailed }
    }

    func stop() {
        generation = UUID()
        for process in Array(processes.values) { cleanup(process) }
        loginProcess = nil
        loginID = nil
        loginState = nil
        loginCodeSubmitted = false
    }

    private func ensureCurrent(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw ClaudeConnectionError.stopped }
    }

    private func prepareDirectory() throws -> URL {
        guard CodexUsageViewerConstants.accountIDs.contains(accountID) else { throw ClaudeConnectionError.invalidAccount }
        let directory = accountRoot.appendingPathComponent(accountID, isDirectory: true)
        for path in [accountRoot.deletingLastPathComponent(), accountRoot, directory] {
            let manager = FileManager.default
            if manager.fileExists(atPath: path.path) {
                guard try manager.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType == .typeDirectory else {
                    throw ClaudeConnectionError.invalidAccount
                }
            } else {
                try manager.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        return directory
    }

    private func start(_ arguments: [String], executable: URL? = nil, extraEnvironment: [String: String] = [:]) throws -> ClaudeProcess {
        if localConfigDirectory != nil {
            guard arguments == ["auth", "status", "--json"], executable == nil, extraEnvironment.isEmpty else {
                throw ClaudeConnectionError.readOnly
            }
        }
        let directory = try localConfigDirectory ?? prepareDirectory()
        let target = executable ?? executableURL
        let child = Process()
        var args = arguments
        child.executableURL = target
        let sharedGroup = CodexConnection.workerLauncherURL != nil
        if let launcher = CodexConnection.workerLauncherURL {
            child.executableURL = launcher
            args = ["--codex-worker", String(getpid()), String(getpgrp()), target.path] + args
        }
        child.arguments = args
        child.currentDirectoryURL = directory
        child.environment = (localConfigDirectory == nil
            ? Self.isolatedEnvironment(executableURL: executableURL, accountDirectory: directory)
            : Self.localIdentityEnvironment(executableURL: executableURL))
            .merging(extraEnvironment) { _, new in new }
        let stdin = Pipe(), stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let captured = ClaudeProcess(process: child, input: stdin.fileHandleForWriting,
                                     output: stdout.fileHandleForReading, sharesHelperGroup: sharedGroup)
        // A browser callback can finish while a manual code is being submitted.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdout.fileHandleForReading.readabilityHandler = { [weak captured] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak captured] in captured?.append(data) }
        }
        processes[captured.id] = captured
        do { try child.run() }
        catch { cleanup(captured); throw ClaudeConnectionError.unavailable }
        return captured
    }

    private func run(_ arguments: [String], executable: URL? = nil, extraEnvironment: [String: String] = [:]) async throws -> (data: Data, status: Int32) {
        let process = try start(arguments, executable: executable, extraEnvironment: extraEnvironment)
        defer { cleanup(process) }
        return try await wait(process, timeout: requestTimeout)
    }

    private func wait(_ process: ClaudeProcess, timeout: TimeInterval) async throws -> (data: Data, status: Int32) {
        let attempt = generation, deadline = Date().addingTimeInterval(timeout)
        while process.process.isRunning {
            try ensureCurrent(attempt)
            guard processes[process.id] != nil else { throw ClaudeConnectionError.stopped }
            if process.overflow { throw ClaudeConnectionError.invalidResponse }
            guard Date() < deadline else { throw ClaudeConnectionError.timedOut }
            try await Task.sleep(for: .milliseconds(25))
        }
        // Allow the last queued pipe read to reach the main actor.
        try await Task.sleep(for: .milliseconds(50))
        try ensureCurrent(attempt)
        guard processes[process.id] != nil else { throw ClaudeConnectionError.stopped }
        guard !process.overflow else { throw ClaudeConnectionError.invalidResponse }
        return (process.data, process.process.terminationStatus)
    }

    private func cleanup(_ process: ClaudeProcess) {
        processes.removeValue(forKey: process.id)
        process.close()
    }

    private func credential(in directory: URL) async throws -> ClaudeOAuthCredential? {
        guard localConfigDirectory == nil else { throw ClaudeConnectionError.readOnly }
        if let loadCredential { return try await loadCredential(directory) }
        let service = Self.keychainService(for: directory)
        let result = try await run(["find-generic-password", "-a", Self.keychainAccount, "-w", "-s", service],
                                   executable: URL(fileURLWithPath: "/usr/bin/security"))
        if result.status == 0 { return try ClaudeOAuthCredential.parse(result.data) }
        // Only fall back when the scoped entry is absent; a locked Keychain isn't an absent login.
        guard result.status == 44 else { throw ClaudeConnectionError.keychainUnavailable }
        let file = directory.appendingPathComponent(".credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else { throw ClaudeConnectionError.invalidResponse }
        return try ClaudeOAuthCredential.parse(Data(contentsOf: file))
    }

    private func usageRequest(token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let fetchUsage { return try await fetchUsage(request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ClaudeNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, data.count <= 1_048_576 else { throw ClaudeConnectionError.invalidResponse }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ClaudeConnectionError { throw error }
        catch { throw ClaudeConnectionError.network }
    }

    static var keychainAccount: String {
        let user = NSUserName()
        return user.range(of: #"\A[a-zA-Z0-9._-]+\z"#, options: .regularExpression) == nil ? "claude-code-user" : user
    }

    static func keychainService(for directory: URL) -> String {
        let normalized = directory.path.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }

    static func credentialExists(accountID: String) -> Bool {
        guard CodexUsageViewerConstants.accountIDs.contains(accountID) else { return false }
        let directory = accountRoot.appendingPathComponent(accountID, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".credentials.json").path) { return true }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService(for: directory),
                                    kSecAttrAccount as String: keychainAccount,
                                    kSecReturnAttributes as String: true,
                                    kSecUseAuthenticationContext as String: context]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Forget only an explicitly removed app-owned slot, even when the CLI is unavailable.
    static func removeCredentials(accountID: String) throws {
        guard CodexUsageViewerConstants.accountIDs.contains(accountID) else { throw ClaudeConnectionError.invalidAccount }
        let directory = accountRoot.appendingPathComponent(accountID, isDirectory: true)
        for parent in [accountRoot.deletingLastPathComponent(), accountRoot] where FileManager.default.fileExists(atPath: parent.path) {
            guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ClaudeConnectionError.invalidAccount
            }
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService(for: directory),
                                    kSecAttrAccount as String: keychainAccount]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClaudeConnectionError.keychainUnavailable }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func isolatedEnvironment(executableURL: URL, accountDirectory: URL,
                                    inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited.filter { key, _ in
            let upper = key.uppercased()
            return !["CLAUDE", "ANTHROPIC_", "CODEX_", "OPENAI_", "CHATGPT_", "OAI_", "AZURE_OPENAI_", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH"].contains(where: upper.hasPrefix)
                && !["ACCESS_TOKEN", "BEARER_TOKEN", "NODE_OPTIONS", "BUN_OPTIONS", "NODE_EXTRA_CA_CERTS", "NODE_TLS_REJECT_UNAUTHORIZED"].contains(upper)
        }
        environment["CLAUDE_CONFIG_DIR"] = accountDirectory.path.precomposedStringWithCanonicalMapping
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["CLAUDE_CODE_SAFE_MODE"] = "1"
        environment["BROWSER"] = "/usr/bin/true"
        environment["NO_COLOR"] = "1"
        let paths = [executableURL.deletingLastPathComponent().path,
                     executableURL.resolvingSymlinksInPath().deletingLastPathComponent().path,
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            + (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    static func localIdentityEnvironment(executableURL: URL,
                                          inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = isolatedEnvironment(executableURL: executableURL,
                                               accountDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                                               inherited: inherited)
        // Setting CLAUDE_CONFIG_DIR would select scoped storage, even for the default path.
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        return environment
    }

    static func locateExecutable(override: String?) -> URL? {
        locateExecutable(override: override, environment: ProcessInfo.processInfo.environment,
                         userDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func locateExecutable(override: String?, environment: [String: String], userDirectory: URL) -> URL? {
        func candidate(_ path: String) -> URL? {
            let expanded = NSString(string: path).expandingTildeInPath
            var directory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &directory),
                  !directory.boolValue, FileManager.default.isExecutableFile(atPath: expanded) else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate(override.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
            + [userDirectory.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
               userDirectory.appendingPathComponent(".npm-global/bin/claude").path]
        if let found = paths.lazy.compactMap(candidate).first { return found }
        let versions = userDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let installed = (try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        return installed.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .lazy.compactMap { candidate($0.appendingPathComponent("bin/claude").path) }.first
    }

    static func validatedLoginURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              ["claude.ai", "claude.com", "console.anthropic.com", "platform.claude.com"].contains(host) else { return nil }
        return parts.url
    }

    static func loginURL(in data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8),
              // A URL is complete only after its whitespace or terminal-escape delimiter arrives.
              // Accepting a match at the end of a pipe chunk can truncate OAuth state or PKCE fields.
              let expression = try? NSRegularExpression(pattern: #"https://[^\s\x00-\x1f<>\"']+(?=[\s\x00-\x1f<>\"'])"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).lazy.compactMap { match -> URL? in
            guard let range = Range(match.range, in: text) else { return nil }
            guard let url = validatedLoginURL(String(text[range])),
                  ["/oauth/authorize", "/cai/oauth/authorize"].contains(url.path) else { return nil }
            return url
        }.first
    }
}

struct ClaudeOAuthCredential {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]

    static func parse(_ data: Data) throws -> ClaudeOAuthCredential? {
        struct OAuth: Decodable { let accessToken: String; let refreshToken: String?; let expiresAt: Double?; let scopes: [String]? }
        struct Document: Decodable { let claudeAiOauth: OAuth? }
        guard data.count <= 1_048_576, let doc = try? JSONDecoder().decode(Document.self, from: data) else {
            throw ClaudeConnectionError.invalidResponse
        }
        guard let oauth = doc.claudeAiOauth else { return nil }
        guard !oauth.accessToken.isEmpty,
              oauth.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              oauth.expiresAt.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw ClaudeConnectionError.invalidResponse }
        return Self(accessToken: oauth.accessToken, refreshToken: oauth.refreshToken,
                    expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }, scopes: oauth.scopes ?? [])
    }
}

enum ClaudeUsageParser {
    static func parse(_ data: Data) throws -> RateLimitsResponse {
        struct Window: Decodable { let utilization: Double; let resets_at: String? }
        struct Usage: Decodable {
            let five_hour: Window?
            let seven_day: Window?
            let seven_day_opus: Window?
            let seven_day_sonnet: Window?
        }
        guard data.count <= 1_048_576, let usage = try? JSONDecoder().decode(Usage.self, from: data) else {
            throw ClaudeConnectionError.invalidResponse
        }
        func window(_ value: Window?, minutes: Int) throws -> QuotaWindow? {
            guard let value else { return nil }
            guard value.utilization.isFinite, value.utilization >= 0 else { throw ClaudeConnectionError.invalidResponse }
            var reset: Int?
            if let string = value.resets_at {
                let format = ISO8601DateFormatter()
                format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let date = format.date(from: string) ?? ISO8601DateFormatter().date(from: string)
                guard let date, date.timeIntervalSince1970 >= 0, date.timeIntervalSince1970 < Double(Int.max) else {
                    throw ClaudeConnectionError.invalidResponse
                }
                reset = Int(date.timeIntervalSince1970)
            }
            return QuotaWindow(usedPercent: value.utilization, windowDurationMins: minutes, resetsAt: reset)
        }
        let primary = try UsageBucket(limitId: "claude", limitName: "Claude", primary: window(usage.five_hour, minutes: 300),
                                      secondary: window(usage.seven_day, minutes: 10_080))
        var buckets = ["claude": primary]
        for (id, name, value) in [("claude_opus", "Opus", usage.seven_day_opus), ("claude_sonnet", "Sonnet", usage.seven_day_sonnet)] {
            if let quota = try window(value, minutes: 10_080) { buckets[id] = UsageBucket(limitId: id, limitName: name, secondary: quota) }
        }
        return RateLimitsResponse(rateLimits: primary, rateLimitsByLimitId: buckets)
    }
}

enum ClaudeConnectionError: LocalizedError, Equatable {
    case invalidAccount, unavailable, outdatedCLI, invalidResponse, subscriptionRequired, signInRequired
    case keychainUnavailable, network, stopped, timedOut, loginInProgress, loginFailed, logoutFailed
    case invalidLoginCode, loginCodeMismatch, loginCodeAlreadySubmitted, readOnly
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidAccount: return "This Claude account’s private sign-in folder is unavailable."
        case .readOnly: return "The local Claude identity connection is read-only."
        case .unavailable: return "Claude Code could not start. Choose its executable in Settings."
        case .outdatedCLI: return "Update Claude Code to version 2.1.268 or later to use isolated accounts."
        case .invalidResponse: return "Claude returned an unreadable response. Update Claude Code and try again."
        case .subscriptionRequired: return "Sign in with a Claude subscription account to read usage limits."
        case .signInRequired: return "Claude sign-in has expired or is unavailable. Reconnect this account."
        case .keychainUnavailable: return "Claude credentials are unavailable. Unlock your login Keychain and refresh."
        case .network: return "Claude usage could not be reached. Check your connection and refresh."
        case .stopped: return "The Claude connection closed. Try refreshing."
        case .timedOut: return "Claude took too long to respond. Try again."
        case .loginInProgress: return "Sign-in is already in progress for this Claude account."
        case .loginFailed: return "Claude sign-in did not complete. Start sign-in again."
        case .invalidLoginCode: return "Paste the complete authentication code, including the part after #."
        case .loginCodeMismatch: return "This code belongs to a different sign-in attempt. Use the browser link from this window."
        case .loginCodeAlreadySubmitted: return "The authentication code has already been submitted. Wait for sign-in to finish."
        case .logoutFailed: return "Claude could not disconnect this account. Try again."
        case .http(let code): return "Claude usage is unavailable (\(code)). Try refreshing later."
        }
    }
}

private final class ClaudeNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
private final class ClaudeProcess {
    let id = UUID()
    let process: Process
    let input: FileHandle
    let output: FileHandle
    let sharesHelperGroup: Bool
    var data = Data()
    var overflow = false

    init(process: Process, input: FileHandle, output: FileHandle, sharesHelperGroup: Bool) {
        self.process = process; self.input = input; self.output = output; self.sharesHelperGroup = sharesHelperGroup
    }
    func append(_ chunk: Data) {
        guard !overflow else { return }
        guard data.count + chunk.count <= 1_048_576 else { overflow = true; data.removeAll(); return }
        data.append(chunk)
    }
    func close() {
        output.readabilityHandler = nil
        try? input.close(); try? output.close()
        Self.terminate(process, sharesHelperGroup: sharesHelperGroup)
        data.removeAll()
    }
    private nonisolated static func terminate(_ process: Process, sharesHelperGroup: Bool) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let group = !sharesHelperGroup && getpgid(pid) == pid
        _ = kill(group ? -pid : pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            guard process.isRunning else { return }
            _ = kill(group && getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
    }
    deinit {
        output.readabilityHandler = nil
        try? input.close(); try? output.close()
        Self.terminate(process, sharesHelperGroup: sharesHelperGroup)
    }
}
