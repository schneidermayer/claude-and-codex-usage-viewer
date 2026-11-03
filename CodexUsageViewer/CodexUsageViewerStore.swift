import AppKit
import Combine
import Foundation
import WidgetKit

struct PendingLogin: Identifiable, Codable, Sendable {
    var id: String
    var accountName: String
    var authURL: URL?
    var isWaiting: Bool
    var error: String?
    var attemptID: String? = nil
    var isSubmittingCode = false
}

@MainActor
struct CodexUsageViewerStoreDependencies {
    var loadSnapshot: () -> UsageSnapshot
    var saveSnapshot: (UsageSnapshot) throws -> Void
    var reloadWidgets: () -> Void
    var locateExecutable: (String?) -> URL?
    var makeConnection: (String, URL) -> any CodexAccountConnection
    var credentialExists: (String) -> Bool
    var discoverChromeProfiles: () -> [ChromeProfile]
    var now: () -> Date
    var readLocalIdentity: (URL) async throws -> CodexIdentity?
    var locateClaudeExecutable: (String?) -> URL? = { ClaudeConnection.locateExecutable(override: $0) }
    var makeClaudeConnection: (String, URL) -> any CodexAccountConnection = { ClaudeConnection(accountID: $0, executableURL: $1) }
    var claudeCredentialExists: (String) -> Bool = { ClaudeConnection.credentialExists(accountID: $0) }
    var readLocalClaudeIdentity: (URL) async throws -> CodexIdentity? = { _ in nil }
    var removeCredentials: (String, AccountProvider) async throws -> Void = { _, _ in }

    static var live: Self {
        Self(loadSnapshot: SharedSnapshotStore.load, saveSnapshot: SharedSnapshotStore.save,
             reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
             locateExecutable: CodexConnection.locateExecutable,
             makeConnection: { CodexConnection(accountID: $0, executableURL: $1) },
             credentialExists: { id in
                 guard CodexUsageViewerConstants.accountIDs.contains(id) else { return false }
                 let root = FileManager.default.homeDirectoryForCurrentUser
                     .appendingPathComponent("Library/Application Support/CodexUsageViewer/Accounts")
                 return FileManager.default.fileExists(atPath: root.appendingPathComponent(id).appendingPathComponent("auth.json").path)
             }, discoverChromeProfiles: ChromeProfile.discover, now: Date.init,
             readLocalIdentity: { try await CodexConnection.readLocalIdentity(executableURL: $0) },
             readLocalClaudeIdentity: { try await ClaudeConnection.readLocalIdentity(executableURL: $0) },
             removeCredentials: { id, provider in
                 // stop() terminates workers and escalates after one second. Let them exit before deleting sign-ins.
                 try await Task.sleep(for: .milliseconds(1_200))
                 if provider == .codex { try CodexConnection.removeCredentials(accountID: id) }
                 else { try ClaudeConnection.removeCredentials(accountID: id) }
             })
    }
}

@MainActor
final class CodexUsageViewerStore: ObservableObject {
    @Published var accounts: [AccountSnapshot]
    @Published var isRefreshing = false
    @Published var isDemo = false
    @Published var errorMessage: String?
    @Published var login: PendingLogin?
    @Published private(set) var backgroundStatus = "Background updates are managed by macOS."
    @Published private(set) var backgroundNeedsApproval = false
    @Published private(set) var backgroundConnected = false
    @Published private(set) var localCodexEmail: String?
    @Published private(set) var localCodexStatus: String?
    @Published private(set) var localCodexCheckedAt: Date?
    @Published private(set) var localClaudeEmail: String?
    @Published private(set) var localClaudeStatus: String?
    @Published private(set) var localClaudeCheckedAt: Date?
    @Published var codexPath: String {
        didSet {
            guard !applyingBackgroundState else { return }
            preferences.set(codexPath, forKey: "codexExecutable")
            if background != nil {
                let path = codexPath
                Task { await sendToBackground(.setExecutable(path: path)) }
                return
            }
            stopConnections(provider: .codex)
            availableCodex = dependencies.locateExecutable(codexPath) != nil
            localCodexEmail = nil
            localCodexCheckedAt = nil
            localCodexStatus = "Refresh to check the local Codex account."
            localLookupID = UUID()
        }
    }
    @Published var claudePath: String {
        didSet {
            guard !applyingBackgroundState else { return }
            preferences.set(claudePath, forKey: "claudeExecutable")
            if background != nil {
                let path = claudePath
                Task { await sendToBackground(.setClaudeExecutable(path: path)) }
                return
            }
            stopConnections(provider: .claude)
            availableClaude = dependencies.locateClaudeExecutable(claudePath) != nil
            localClaudeEmail = nil
            localClaudeCheckedAt = nil
            localClaudeStatus = "Refresh to check the local Claude account."
            localClaudeLookupID = UUID()
        }
    }
    @Published private(set) var availableCodex: Bool
    @Published private(set) var availableClaude: Bool
    @Published private(set) var chromeProfiles: [ChromeProfile]
    @Published private(set) var busyAccountIDs: Set<String> = []
    var openDashboardAction: (() -> Void)?
    private let dependencies: CodexUsageViewerStoreDependencies
    private let preferences: UserDefaults
    private let isUITesting: Bool
    private let managesChromeProfiles: Bool
    private let background: (any BackgroundServing)?
    private let backgroundService: BackgroundServiceRegistration?
    private var applyingBackgroundState = false
    private var backgroundRequestID = 0
    private var appliedBackgroundRequestID = 0
    private var stopped = false
    private var connections: [String: any CodexAccountConnection] = [:]
    private var liveAccounts: [AccountSnapshot]
    private var pollTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var activeLoginID: String?
    private var loginAttemptID: UUID?
    private var pendingDisconnectIDs: Set<String> = []
    private var isChangingAccounts = false
    private var profileSelections: [String: String]
    private var localLookupID = UUID()
    private var localClaudeLookupID = UUID()

    func isLocalAccount(_ account: AccountSnapshot) -> Bool {
        guard !isDemo else { return false }
        var snapshot = UsageSnapshot(accounts: accounts, savedAt: dependencies.now())
        snapshot.localCodexEmail = localCodexEmail
        snapshot.localCodexCheckedAt = localCodexCheckedAt
        snapshot.localClaudeEmail = localClaudeEmail
        snapshot.localClaudeCheckedAt = localClaudeCheckedAt
        return snapshot.isLocalAccount(account, at: dependencies.now())
    }

    func localStatus(for provider: AccountProvider) -> String? {
        provider == .codex ? localCodexStatus : localClaudeStatus
    }

    var selectedChromeProfileID: String {
        get {
            guard let selected = login.flatMap({ profileSelections[$0.id] }),
                  chromeProfiles.contains(where: { $0.id == selected }) else { return "" }
            return selected
        }
        set {
            guard let id = login?.id else { return }
            objectWillChange.send()
            if chromeProfiles.contains(where: { $0.id == newValue }) {
                profileSelections[id] = newValue
            } else {
                profileSelections.removeValue(forKey: id)
            }
            preferences.set(profileSelections, forKey: "chromeProfiles")
        }
    }

    func openSignInInChrome() {
        guard let url = login?.authURL, !selectedChromeProfileID.isEmpty else { return }
        let profileID = selectedChromeProfileID
        guard chromeProfiles.contains(where: { $0.id == profileID }) else { return }
        let attempt = loginAttemptID
        let accountID = login?.id
        Task {
            do { try await ChromeProfile.open(url, profileID: profileID) }
            catch {
                guard loginAttemptID == attempt, login?.id == accountID, login?.authURL == url else { return }
                login?.error = "Chrome couldn’t open this profile. You can still copy the sign-in link and open it yourself."
            }
        }
    }

    convenience init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let testSuite = "com.inndevs.codexusageviewer.uitesting"
        let preferences = testing ? UserDefaults(suiteName: testSuite)! : .standard
        if testing { preferences.removePersistentDomain(forName: testSuite) }
        self.init(dependencies: .live, preferences: preferences, startsPolling: true,
                  arguments: ProcessInfo.processInfo.arguments,
                  background: testing ? nil : BackgroundClient(), managesBackgroundService: !testing)
    }

    init(dependencies: CodexUsageViewerStoreDependencies, preferences: UserDefaults,
         startsPolling: Bool = false, arguments: [String] = [],
         background: (any BackgroundServing)? = nil, managesBackgroundService: Bool = false,
         managesChromeProfiles: Bool = true) {
        self.dependencies = dependencies
        self.preferences = preferences
        isUITesting = arguments.contains("--ui-testing")
        self.managesChromeProfiles = managesChromeProfiles
        self.background = isUITesting ? nil : background
        backgroundService = managesBackgroundService && !isUITesting ? BackgroundServiceRegistration() : nil
        profileSelections = managesChromeProfiles ? preferences.dictionary(forKey: "chromeProfiles") as? [String: String] ?? [:] : [:]
        let discoveredProfiles = managesChromeProfiles ? dependencies.discoverChromeProfiles() : []
        chromeProfiles = discoveredProfiles
        profileSelections = profileSelections.filter { _, profileID in discoveredProfiles.contains(where: { $0.id == profileID }) }
        if managesChromeProfiles { preferences.set(profileSelections, forKey: "chromeProfiles") }
        let path = preferences.string(forKey: "codexExecutable") ?? ""
        codexPath = path
        availableCodex = dependencies.locateExecutable(path) != nil
        let claudeExecutable = preferences.string(forKey: "claudeExecutable") ?? ""
        claudePath = claudeExecutable
        availableClaude = dependencies.locateClaudeExecutable(claudeExecutable) != nil
        let cachedSnapshot = isUITesting ? UsageSnapshot.empty : SharedSnapshotStore.normalized(dependencies.loadSnapshot())
        var cached = cachedSnapshot.accounts
        if !isUITesting {
            // Check app-owned credential existence, without reading tokens.
            for index in cached.indices where cached[index].state == .disconnected {
                let exists = cached[index].provider == .codex
                    ? dependencies.credentialExists(cached[index].id)
                    : dependencies.claudeCredentialExists(cached[index].id)
                if exists {
                    cached[index].state = .needsSignIn
                }
            }
        }
        accounts = cached
        liveAccounts = cached
        localCodexEmail = cachedSnapshot.localCodexEmail
        localCodexCheckedAt = cachedSnapshot.localCodexCheckedAt
        localClaudeEmail = cachedSnapshot.localClaudeEmail
        localClaudeCheckedAt = cachedSnapshot.localClaudeCheckedAt
        if arguments.contains("--demo") {
            isDemo = true
            accounts = UsageSnapshot.preview.accounts
        }
        if isUITesting && arguments.contains("--ui-testing-connected") {
            accounts = UsageSnapshot.preview.accounts
            liveAccounts = accounts
            isDemo = false
            localCodexEmail = accounts.first?.email
            localCodexCheckedAt = dependencies.now()
            localClaudeEmail = accounts.first(where: { $0.provider == .claude })?.email
            localClaudeCheckedAt = dependencies.now()
        }
        if isUITesting && arguments.contains("--ui-testing-login-code") {
            accounts = [AccountSnapshot(id: "account-1", name: "Account", provider: .claude)]
            liveAccounts = accounts
            login = PendingLogin(id: "account-1", accountName: "Account 1",
                                 authURL: URL(string: "https://claude.com/cai/oauth/authorize?state=fixture"),
                                 isWaiting: true, attemptID: "fixture-attempt")
        }
        updateLocalCodexMatchStatus()
        updateLocalClaudeMatchStatus()
        if startsPolling && !isUITesting {
            pollTask = Task { [weak self] in
                await self?.backgroundService?.registerIfNeeded()
                while !Task.isCancelled {
                    if self?.background != nil {
                        await self?.sendToBackground(.state)
                    } else {
                        await self?.refresh()
                    }
                    let interval = self?.background == nil ? CodexUsageViewerConstants.refreshInterval : 2
                    do { try await Task.sleep(for: .seconds(interval)) }
                    catch { return }
                }
            }
        }
    }

    private func connection(for id: String) throws -> any CodexAccountConnection {
        if let connection = connections[id] { return connection }
        guard CodexUsageViewerConstants.accountIDs.contains(id),
              let account = accounts.first(where: { $0.id == id }) else { throw CodexConnectionError.invalidAccount }
        let executable = account.provider == .codex
            ? dependencies.locateExecutable(codexPath) : dependencies.locateClaudeExecutable(claudePath)
        guard let executable else {
            throw NSError(domain: "CodexUsageViewer", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(account.provider.displayName) CLI wasn’t found. Choose its executable in Settings, then try again."])
        }
        let connection = account.provider == .codex
            ? dependencies.makeConnection(id, executable) : dependencies.makeClaudeConnection(id, executable)
        connections[id] = connection
        return connection
    }

    private func stopConnections(provider: AccountProvider) {
        for account in accounts where account.provider == provider {
            connections.removeValue(forKey: account.id)?.stop()
        }
    }

    var canManageAccounts: Bool {
        !stopped && !isDemo && !isRefreshing && !isChangingAccounts && login == nil && loginTask == nil
            && busyAccountIDs.isEmpty && pendingDisconnectIDs.isEmpty
    }
    var canAddAccount: Bool { canManageAccounts && accounts.count < 3 }
    var canRemoveAccount: Bool { canManageAccounts && accounts.count > 1 }

    func addAccount(provider: AccountProvider) async {
        guard canAddAccount else { return }
        if background != nil { await sendToBackground(.addAccount(provider: provider)); return }
        guard let id = CodexUsageViewerConstants.accountIDs.first(where: { id in !accounts.contains { $0.id == id } }) else { return }
        accounts.append(AccountSnapshot(id: id, name: "Account", provider: provider))
        persist()
    }

    func setProvider(_ provider: AccountProvider, for id: String) async {
        guard canManageAccounts, let index = accounts.firstIndex(where: { $0.id == id }),
              accounts[index].state == .disconnected, accounts[index].provider != provider else { return }
        if background != nil { await sendToBackground(.setProvider(accountID: id, provider: provider)); return }
        connections.removeValue(forKey: id)?.stop()
        accounts[index] = AccountSnapshot(id: id, name: accounts[index].name, provider: provider)
        profileSelections.removeValue(forKey: id)
        if managesChromeProfiles { preferences.set(profileSelections, forKey: "chromeProfiles") }
        persist()
    }

    func removeAccount(_ id: String) async {
        guard canRemoveAccount, let account = accounts.first(where: { $0.id == id }) else { return }
        if background != nil { await sendToBackground(.removeAccount(accountID: id)); return }
        isChangingAccounts = true
        pendingDisconnectIDs.insert(id)
        busyAccountIDs.insert(id)
        defer { pendingDisconnectIDs.remove(id); busyAccountIDs.remove(id); isChangingAccounts = false }
        connections.removeValue(forKey: id)?.stop()
        do {
            if !isUITesting { try await dependencies.removeCredentials(id, account.provider) }
            guard !stopped else { return }
            accounts.removeAll { $0.id == id }
            profileSelections.removeValue(forKey: id)
            if managesChromeProfiles { preferences.set(profileSelections, forKey: "chromeProfiles") }
            updateLocalCodexMatchStatus()
            updateLocalClaudeMatchStatus()
            persist()
        } catch { errorMessage = "Couldn’t remove account: \(error.localizedDescription)" }
    }

    func refresh() async {
        guard !stopped, !isDemo, !isUITesting, !isRefreshing, !isChangingAccounts else { return }
        if background != nil { await sendToBackground(.refresh); return }
        availableCodex = dependencies.locateExecutable(codexPath) != nil
        availableClaude = dependencies.locateClaudeExecutable(claudePath) != nil
        isRefreshing = true
        defer { isRefreshing = false }
        async let localRefresh: Void = refreshLocalCodexIdentity()
        async let localClaudeRefresh: Void = refreshLocalClaudeIdentity()
        for id in accounts.map(\.id) {
            guard let account = accounts.first(where: { $0.id == id }),
                  account.state != .disconnected, login?.id != id else { continue }
            await refreshAccount(id)
        }
        await localRefresh
        await localClaudeRefresh
        updateLocalCodexMatchStatus()
        updateLocalClaudeMatchStatus()
        persist()
    }

    private func refreshLocalCodexIdentity() async {
        guard !isDemo, !isUITesting else { return }
        let lookup = UUID()
        localLookupID = lookup
        guard let executable = dependencies.locateExecutable(codexPath) else {
            localCodexEmail = nil
            localCodexCheckedAt = nil
            localCodexStatus = "Choose the Codex CLI to detect your local account."
            return
        }
        do {
            let identity = try await dependencies.readLocalIdentity(executable)
            guard localLookupID == lookup, !isDemo else { return }
            localCodexCheckedAt = dependencies.now()
            guard let identity else {
                localCodexEmail = nil
                localCodexStatus = "Local Codex isn’t signed in."
                return
            }
            guard identity.type == "chatgpt", let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
                localCodexEmail = nil
                localCodexStatus = identity.type == "apiKey" ? "Local Codex uses API-key authentication." : "Local Codex didn’t return an account email."
                return
            }
            localCodexEmail = email
            updateLocalCodexMatchStatus()
        } catch {
            guard localLookupID == lookup else { return }
            localCodexEmail = nil
            localCodexCheckedAt = nil
            localCodexStatus = "Local Codex identity couldn’t be read. Refresh to try again."
        }
    }

    private func updateLocalCodexMatchStatus() {
        guard !isDemo else { localCodexStatus = nil; return }
        guard localCodexEmail != nil, let checkedAt = localCodexCheckedAt else { return }
        let age = dependencies.now().timeIntervalSince(checkedAt)
        guard age >= -60, age <= CodexUsageViewerConstants.staleInterval else {
            localCodexStatus = "Refresh to check the local Codex account."
            return
        }
        if let account = accounts.first(where: { $0.provider == .codex && isLocalAccount($0) }) {
            localCodexStatus = "Local Codex is using \(account.displayName)."
        } else {
            localCodexStatus = "Local Codex uses an account that isn’t connected here."
        }
    }

    private func refreshLocalClaudeIdentity() async {
        guard !stopped, !isDemo, !isUITesting else { return }
        guard accounts.contains(where: { $0.provider == .claude }) else { return }
        let lookup = UUID()
        localClaudeLookupID = lookup
        guard let executable = dependencies.locateClaudeExecutable(claudePath) else {
            localClaudeEmail = nil
            localClaudeCheckedAt = nil
            localClaudeStatus = "Choose the Claude CLI to detect your local account."
            return
        }
        do {
            let identity = try await dependencies.readLocalClaudeIdentity(executable)
            guard localClaudeLookupID == lookup, !stopped, !isDemo else { return }
            localClaudeCheckedAt = dependencies.now()
            guard let identity else {
                localClaudeEmail = nil
                localClaudeStatus = "Local Claude isn’t signed in."
                return
            }
            guard identity.type == "claude", let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
                localClaudeEmail = nil
                localClaudeStatus = "Local Claude didn’t return a subscription account email."
                return
            }
            localClaudeEmail = email
            updateLocalClaudeMatchStatus()
        } catch {
            guard localClaudeLookupID == lookup else { return }
            localClaudeEmail = nil
            localClaudeCheckedAt = nil
            localClaudeStatus = "Local Claude identity couldn’t be read. Refresh to try again."
        }
    }

    private func updateLocalClaudeMatchStatus() {
        guard !isDemo else { localClaudeStatus = nil; return }
        guard localClaudeEmail != nil, let checkedAt = localClaudeCheckedAt else { return }
        let age = dependencies.now().timeIntervalSince(checkedAt)
        guard age >= -60, age <= CodexUsageViewerConstants.staleInterval else {
            localClaudeStatus = "Refresh to check the local Claude account."
            return
        }
        if let account = accounts.first(where: { $0.provider == .claude && isLocalAccount($0) }) {
            localClaudeStatus = "Local Claude is using \(account.displayName)."
        } else {
            localClaudeStatus = "Local Claude uses an account that isn’t connected here."
        }
    }

    private func refreshAccount(_ id: String) async {
        guard !busyAccountIDs.contains(id), !pendingDisconnectIDs.contains(id), let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        busyAccountIDs.insert(id)
        defer { busyAccountIDs.remove(id) }
        do {
            let worker = try connection(for: id)
            guard let identity = try await worker.account(), identity.type == accounts[index].provider.identityType else {
                accounts[index].state = .needsSignIn
                accounts[index].buckets = []
                accounts[index].resetCredits = nil
                accounts[index].updatedAt = nil
                accounts[index].issue = "Sign in to reconnect this account."
                return
            }
            if accounts[index].email != identity.email || accounts[index].plan != identity.planType {
                accounts[index].buckets = []
                accounts[index].resetCredits = nil
                accounts[index].updatedAt = nil
            }
            accounts[index].email = identity.email
            accounts[index].plan = identity.planType
            accounts[index].fullName = identity.fullName
            accounts[index].state = .connected
            let limits = try await worker.readLimits()
            accounts[index].buckets = limits.buckets
            accounts[index].resetCredits = limits.rateLimitResetCredits
            accounts[index].updatedAt = dependencies.now()
            accounts[index].issue = nil
        } catch {
            accounts[index].issue = error.localizedDescription
            if let claudeError = error as? ClaudeConnectionError,
               claudeError == .signInRequired || claudeError == .subscriptionRequired {
                accounts[index].state = .needsSignIn
                accounts[index].buckets = []
                accounts[index].resetCredits = nil
                accounts[index].updatedAt = nil
            }
            // Transient failures preserve the last successful snapshot with its original age.
        }
    }

    func connect(_ accountID: String) async {
        guard !stopped, !isChangingAccounts, !isDemo, !isUITesting, login == nil, loginTask == nil, !busyAccountIDs.contains(accountID), !pendingDisconnectIDs.contains(accountID), let account = accounts.first(where: { $0.id == accountID }) else { return }
        if managesChromeProfiles {
            chromeProfiles = dependencies.discoverChromeProfiles()
            profileSelections = profileSelections.filter { _, profileID in chromeProfiles.contains(where: { $0.id == profileID }) }
            preferences.set(profileSelections, forKey: "chromeProfiles")
        }
        if background != nil { await sendToBackground(.connect(accountID: accountID)); return }
        let attempt = UUID()
        loginAttemptID = attempt
        login = PendingLogin(id: accountID, accountName: account.displayName, isWaiting: true)
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { if loginAttemptID == attempt { loginTask = nil } }
            do {
                let worker = try connection(for: accountID)
                let result = try await worker.beginLogin()
                guard !Task.isCancelled, loginAttemptID == attempt else {
                    await worker.cancelLogin(loginID: result.loginId)
                    return
                }
                activeLoginID = result.loginId
                login?.attemptID = result.loginId
                login?.authURL = result.authURL
                try await worker.waitForLogin(loginID: result.loginId)
                guard !Task.isCancelled, loginAttemptID == attempt else { return }
                if let index = accounts.firstIndex(where: { $0.id == accountID }) {
                    accounts[index] = AccountSnapshot(id: accountID, name: accounts[index].name, state: .needsSignIn, provider: accounts[index].provider)
                }
                await refreshAccount(accountID)
                if account.provider == .claude { await refreshLocalClaudeIdentity() }
                else { await refreshLocalCodexIdentity() }
                persist()
                if accounts.first(where: { $0.id == accountID })?.isConnected == true {
                    login = nil
                    activeLoginID = nil
                } else {
                    login?.isSubmittingCode = false
                    login?.isWaiting = false
                    login?.error = accounts.first(where: { $0.id == accountID })?.issue ?? "Sign-in finished, but usage could not be read. Close this window and refresh to try again."
                }
            } catch {
                guard !Task.isCancelled, loginAttemptID == attempt else { return }
                login?.isSubmittingCode = false
                login?.isWaiting = false
                login?.error = error.localizedDescription
            }
        }
    }

    /// Codes cross the authenticated app/helper channel only; they are never stored in state or snapshots.
    func submitLoginCode(_ code: String, accountID: String? = nil, loginID: String? = nil) async {
        guard !stopped, !isDemo, let pending = login, pending.isWaiting, !pending.isSubmittingCode,
              let attempt = pending.attemptID,
              accountID == nil || accountID == pending.id,
              loginID == nil || loginID == attempt,
              accounts.first(where: { $0.id == pending.id })?.provider == .claude else { return }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, code.utf8.count <= 8_192 else {
            login?.error = "Paste the complete authentication code from Claude."
            return
        }
        login?.isSubmittingCode = true
        login?.error = nil
        if isUITesting {
            login = nil
            return
        }
        if background != nil {
            await sendToBackground(.submitLoginCode(accountID: pending.id, loginID: attempt, code: code))
            return
        }
        do {
            guard activeLoginID == attempt, let worker = connections[pending.id] else { throw ClaudeConnectionError.stopped }
            try await worker.submitLoginCode(code: code, loginID: attempt)
            // Keep submission disabled until the original login task finishes exchanging the code.
        } catch {
            guard login?.id == pending.id, login?.attemptID == attempt else { return }
            login?.isSubmittingCode = false
            // The CLI's raw diagnostics may include credentials; only known safe errors reach the UI.
            login?.error = (error as? ClaudeConnectionError)?.localizedDescription
                ?? "Claude couldn’t accept this authentication code. Start sign-in again."
        }
    }

    func cancelLogin() async {
        if background != nil {
            guard login != nil else { return }
            await sendToBackground(.cancelLogin)
            return
        }
        // Multiple dismissal callbacks may cancel; only the first owns cleanup.
        guard let accountID = login?.id else { return }
        let loginID = activeLoginID
        let task = loginTask
        loginAttemptID = nil
        // Wait for an in-flight start to return the ID needed to cancel its login.
        if loginID != nil { task?.cancel() }
        activeLoginID = nil
        login = nil
        if let loginID {
            await connections[accountID]?.cancelLogin(loginID: loginID)
        }
        await task?.value
        loginTask = nil
        // A browser callback may have completed just as Cancel was pressed.
        if !isDemo, !pendingDisconnectIDs.contains(accountID) {
            await refreshAccount(accountID)
            if let index = accounts.firstIndex(where: { $0.id == accountID }), accounts[index].email == nil, accounts[index].state == .needsSignIn {
                accounts[index].state = .disconnected
                accounts[index].issue = nil
            }
            persist()
        }
    }

    func disconnect(_ accountID: String) async {
        guard !stopped, !isChangingAccounts, !isDemo, !isUITesting, let index = accounts.firstIndex(where: { $0.id == accountID }), !pendingDisconnectIDs.contains(accountID) else { return }
        if background != nil { await sendToBackground(.disconnect(accountID: accountID)); return }
        pendingDisconnectIDs.insert(accountID)
        var ownsBusyState = false
        defer {
            pendingDisconnectIDs.remove(accountID)
            if ownsBusyState { busyAccountIDs.remove(accountID) }
        }
        if login?.id == accountID { await cancelLogin() }
        while busyAccountIDs.contains(accountID) {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        busyAccountIDs.insert(accountID)
        ownsBusyState = true
        do {
            let worker = try connection(for: accountID)
            try await worker.disconnect()
            worker.stop()
            connections.removeValue(forKey: accountID)
            accounts[index] = AccountSnapshot(id: accountID, name: accounts[index].name, provider: accounts[index].provider)
            updateLocalCodexMatchStatus()
            updateLocalClaudeMatchStatus()
            persist()
        } catch { errorMessage = "Couldn’t disconnect: \(error.localizedDescription)" }
    }

    func setDemo(_ enabled: Bool) {
        guard login == nil, loginTask == nil, !isRefreshing, busyAccountIDs.isEmpty, pendingDisconnectIDs.isEmpty else { return }
        if enabled && !isDemo {
            liveAccounts = accounts
            accounts = UsageSnapshot.preview.accounts
        } else if !enabled && isDemo {
            accounts = liveAccounts
        }
        isDemo = enabled
        updateLocalCodexMatchStatus()
        updateLocalClaudeMatchStatus()
    }

    func openDashboard() {
        openDashboardAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() {
        stopped = true
        pollTask?.cancel()
        background?.shutdown()
        loginTask?.cancel()
        localLookupID = UUID()
        localClaudeLookupID = UUID()
        connections.values.forEach { $0.stop() }
    }

    /// Only the helper publishes widget snapshots; the app never opens account workers.
    func sendToBackground(_ command: BackgroundCommand) async {
        guard !stopped, let background else { return }
        if let service = backgroundService {
            backgroundNeedsApproval = service.needsApproval
            if let issue = service.issue {
                backgroundConnected = false
                backgroundStatus = issue
                errorMessage = issue
                return
            }
        }
        backgroundRequestID += 1
        let requestID = backgroundRequestID
        do {
            let state = try await background.send(command)
            guard !stopped, requestID >= appliedBackgroundRequestID else { return }
            appliedBackgroundRequestID = requestID
            liveAccounts = state.snapshot.accounts
            if !isDemo { accounts = liveAccounts }
            localCodexEmail = state.snapshot.localCodexEmail
            localCodexCheckedAt = state.snapshot.localCodexCheckedAt
            localCodexStatus = state.localCodexStatus
            localClaudeEmail = state.snapshot.localClaudeEmail
            localClaudeCheckedAt = state.snapshot.localClaudeCheckedAt
            localClaudeStatus = state.localClaudeStatus
            isRefreshing = state.isRefreshing
            busyAccountIDs = Set(state.busyAccountIDs)
            login = state.login
            availableCodex = state.availableCodex
            availableClaude = state.availableClaude
            errorMessage = state.errorMessage
            applyingBackgroundState = true
            codexPath = state.codexPath
            claudePath = state.claudePath
            applyingBackgroundState = false
            backgroundStatus = "Active · updates continue after you quit the app."
            backgroundNeedsApproval = false
            backgroundConnected = true
        } catch {
            guard !stopped, requestID >= appliedBackgroundRequestID else { return }
            appliedBackgroundRequestID = requestID
            backgroundConnected = false
            isRefreshing = false
            backgroundStatus = "Background helper unavailable. Reopen the app or check Login Items in System Settings."
            errorMessage = backgroundStatus
        }
    }

    func retryBackgroundService() async {
        await backgroundService?.registerIfNeeded()
        await sendToBackground(.state)
    }

    var backgroundState: BackgroundState {
        var snapshot = UsageSnapshot(accounts: accounts, savedAt: dependencies.now())
        snapshot.localCodexEmail = localCodexEmail
        snapshot.localCodexCheckedAt = localCodexCheckedAt
        snapshot.localClaudeEmail = localClaudeEmail
        snapshot.localClaudeCheckedAt = localClaudeCheckedAt
        return BackgroundState(snapshot: snapshot, isRefreshing: isRefreshing,
                               busyAccountIDs: Array(busyAccountIDs), login: login,
                               availableCodex: availableCodex, localCodexStatus: localCodexStatus,
                               errorMessage: errorMessage, codexPath: codexPath,
                               availableClaude: availableClaude, claudePath: claudePath, localClaudeStatus: localClaudeStatus)
    }

    private func persist() {
        guard !stopped, background == nil, !isDemo, !isUITesting else { return }
        liveAccounts = accounts
        do {
            var snapshot = UsageSnapshot(accounts: accounts, savedAt: dependencies.now())
            snapshot.localCodexEmail = localCodexEmail
            snapshot.localCodexCheckedAt = localCodexCheckedAt
            snapshot.localClaudeEmail = localClaudeEmail
            snapshot.localClaudeCheckedAt = localClaudeCheckedAt
            try dependencies.saveSnapshot(snapshot)
            dependencies.reloadWidgets()
        } catch { errorMessage = error.localizedDescription }
    }
}
