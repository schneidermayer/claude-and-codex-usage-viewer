import Foundation
import XCTest
@testable import CodexUsageViewerCore

@MainActor
final class ClaudeConnectionTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let executable: URL
        var root: URL { base.appendingPathComponent("app/ClaudeAccounts") }
        @MainActor func connection(loginTimeout: TimeInterval = 2,
                        load: ((URL) async throws -> ClaudeOAuthCredential?)? = nil,
                        fetch: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) -> ClaudeConnection {
            ClaudeConnection(accountID: "account-1", executableURL: executable, accountRoot: root,
                             requestTimeout: 5, loginTimeout: loginTimeout, loadCredential: load, fetchUsage: fetch)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
    private func fixture(mode: String = "normal") throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("claudeusage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let executable = base.appendingPathComponent("claude")
        let script = """
        #!/usr/bin/python3
        import json, os, sys, time
        mode = '\(mode)'
        local = mode.startswith('local-')
        folder = os.path.join(os.path.dirname(__file__), 'local') if local else os.environ['CLAUDE_CONFIG_DIR']
        assert os.getcwd() == os.path.realpath(folder)
        assert 'ANTHROPIC_API_KEY' not in os.environ
        if local:
            assert 'CLAUDE_CONFIG_DIR' not in os.environ
            assert sys.argv[1:] == ['auth', 'status', '--json']
            open(os.path.join(os.path.dirname(__file__), 'local-transcript'), 'w').write('auth status --json')
            if mode == 'local-wait':
                time.sleep(60)
        if sys.argv[1:3] == ['auth', 'status']:
            print(json.dumps({'loggedIn': mode != 'local-signed-out', 'authMethod': 'api_key' if mode == 'local-api-key' else 'claude.ai', 'email': 'claude@example.com', 'subscriptionType': 'pro', 'configDirectory': '/tmp/wrong' if mode.endswith('wrong-directory') else folder}), flush=True)
            if mode == 'local-signed-out':
                sys.exit(1)
        elif sys.argv[1:3] == ['auth', 'login']:
            if os.environ.get('CLAUDE_CODE_OAUTH_REFRESH_TOKEN'):
                assert os.environ['CLAUDE_CODE_OAUTH_SCOPES'] == 'user:profile'
                open(os.path.join(folder, 'renewed'), 'w').write('yes')
                print('Login successful.', flush=True)
            else:
                if mode == 'split-link':
                    sys.stdout.write('If the browser did not open, visit: https://claude.com/cai/oauth/authorize?state=fix')
                    sys.stdout.flush()
                    time.sleep(0.2)
                    print('ture&code_challenge=complete', flush=True)
                else:
                    print('If the browser did not open, visit: https://claude.ai/oauth/authorize?state=fixture', flush=True)
                if mode in ('manual-code', 'manual-code-rejected'):
                    line = sys.stdin.readline()
                    if line != 'synthetic-code#fixture\\n':
                        sys.exit(19)
                    if mode == 'manual-code-rejected':
                        sys.stderr.write('private provider diagnostic must not be surfaced')
                        sys.exit(1)
                    print('Login successful.', flush=True)
                elif mode == 'wait':
                    time.sleep(60)
                else:
                    time.sleep(0.15)
        elif sys.argv[1:3] == ['auth', 'logout']:
            open(os.path.join(folder, 'logout'), 'w').write('yes')
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return Fixture(base: base, executable: executable)
    }

    func testOfficialIdentityRequiresMatchingIsolatedDirectory() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        let identity = try await connection.account()
        XCTAssertEqual(identity?.type, "claude")
        XCTAssertEqual(identity?.email, "claude@example.com")
        XCTAssertEqual(identity?.planType, "pro")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("account-1").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLocalIdentityUsesOnlyStatusWithoutChangingDefaultStorage() async throws {
        let fixture = try fixture(mode: "local-normal")
        defer { fixture.remove() }
        let directory = fixture.base.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o755])
        let sentinel = directory.appendingPathComponent(".credentials.json")
        let original = Data("Not a credential; the viewer must never parse this file.".utf8)
        try original.write(to: sentinel)
        let identity = try await ClaudeConnection.readLocalIdentity(executableURL: fixture.executable, configDirectory: directory)
        XCTAssertEqual(identity?.email, "claude@example.com")
        XCTAssertEqual(identity?.type, "claude")
        XCTAssertNil(identity?.fullName)
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [".credentials.json"])
        XCTAssertEqual(try String(contentsOf: fixture.base.appendingPathComponent("local-transcript")), "auth status --json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testMissingLocalDirectoryDoesNotStartCLIOrCreateStorage() async throws {
        let fixture = try fixture(mode: "local-normal")
        defer { fixture.remove() }
        let directory = fixture.base.appendingPathComponent("local")
        let identity = try await ClaudeConnection.readLocalIdentity(executableURL: fixture.executable, configDirectory: directory)
        XCTAssertNil(identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("local-transcript").path))
    }

    func testLocalStatusRejectsWrongDirectoryAndAPIKeysAndAllowsSignedOut() async throws {
        for (mode, expected) in [("local-wrong-directory", ClaudeConnectionError.outdatedCLI), ("local-api-key", .subscriptionRequired)] {
            let fixture = try fixture(mode: mode)
            defer { fixture.remove() }
            let directory = fixture.base.appendingPathComponent("local")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                _ = try await ClaudeConnection.readLocalIdentity(executableURL: fixture.executable, configDirectory: directory)
                XCTFail("Expected local identity rejection")
            } catch { XCTAssertEqual(error as? ClaudeConnectionError, expected) }
        }
        let fixture = try fixture(mode: "local-signed-out")
        defer { fixture.remove() }
        let directory = fixture.base.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = try await ClaudeConnection.readLocalIdentity(executableURL: fixture.executable, configDirectory: directory)
        XCTAssertNil(identity)
    }

    func testLocalStatusHasBoundedWaitAndFiltersInheritedAuthenticationOverrides() async throws {
        let fixture = try fixture(mode: "local-wait")
        defer { fixture.remove() }
        let directory = fixture.base.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            _ = try await ClaudeConnection.readLocalIdentity(executableURL: fixture.executable, configDirectory: directory, requestTimeout: 0.1)
            XCTFail("Expected bounded local lookup")
        } catch { XCTAssertEqual(error as? ClaudeConnectionError, .timedOut) }
        let environment = ClaudeConnection.localIdentityEnvironment(executableURL: fixture.executable, inherited: [
            "CLAUDE_CONFIG_DIR": "/other-account", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/other-keychain",
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic", "ANTHROPIC_API_KEY": "synthetic", "NODE_OPTIONS": "--require fixture"
        ])
        for key in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "NODE_OPTIONS"] {
            XCTAssertNil(environment[key])
        }
        XCTAssertEqual(environment["BROWSER"], "/usr/bin/true")
    }

    func testWrongDirectoryIsRejectedBeforeLogin() async throws {
        let fixture = try fixture(mode: "wrong-directory")
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        do { _ = try await connection.beginLogin(); XCTFail("Expected isolation rejection") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .outdatedCLI) }
    }

    func testLoginURLAndCompletion() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        let login = try await connection.beginLogin()
        XCTAssertEqual(login.authURL.host, "claude.ai")
        try await connection.waitForLogin(loginID: login.loginId)
        try await connection.disconnect()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("account-1/logout").path))
    }

    func testCurrentClaudeDomainAndSplitLoginURL() async throws {
        let fixture = try fixture(mode: "split-link")
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        let login = try await connection.beginLogin()
        XCTAssertEqual(login.authURL.absoluteString, "https://claude.com/cai/oauth/authorize?state=fixture&code_challenge=complete")
        try await connection.waitForLogin(loginID: login.loginId)
    }

    func testLoginURLParserWaitsForTerminatorAndHandlesTerminalHyperlinks() {
        let url = "https://claude.com/cai/oauth/authorize?state=fixture&code_challenge=complete"
        XCTAssertNil(ClaudeConnection.loginURL(in: Data(url.utf8)))
        XCTAssertNil(ClaudeConnection.loginURL(in: Data("\(url)".dropLast(8).utf8)))
        XCTAssertEqual(ClaudeConnection.loginURL(in: Data("\(url)\n".utf8))?.absoluteString, url)
        let hyperlink = "\u{001B}]8;;\(url)\u{001B}\\Sign in\u{001B}]8;;\u{001B}\\"
        XCTAssertEqual(ClaudeConnection.loginURL(in: Data(hyperlink.utf8))?.absoluteString, url)
        XCTAssertNil(ClaudeConnection.loginURL(in: Data("Read https://claude.com/docs\n".utf8)))
    }

    /// Explicit smoke only: start the installed CLI in an empty private directory and cancel before sign-in.
    func testInstalledClaudeCLIReturnsCompleteLoginURL() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_USAGE_LIVE_CLI_SMOKE"] == "1" else {
            throw XCTSkip("Set CLAUDE_USAGE_LIVE_CLI_SMOKE=1 to check the installed CLI without signing in.")
        }
        guard let executable = ClaudeConnection.locateExecutable(override: nil) else { throw XCTSkip("Claude Code is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudeusage-live-smoke-\(UUID().uuidString)/app/ClaudeAccounts")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let connection = ClaudeConnection(accountID: "account-1", executableURL: executable, accountRoot: root, requestTimeout: 10)
        defer { connection.stop() }
        let identity = try await connection.account()
        XCTAssertNil(identity)
        let login = try await connection.beginLogin()
        XCTAssertTrue(["claude.ai", "claude.com"].contains(login.authURL.host ?? ""))
        XCTAssertTrue(["/oauth/authorize", "/cai/oauth/authorize"].contains(login.authURL.path))
        let components = try XCTUnwrap(URLComponents(url: login.authURL, resolvingAgainstBaseURL: false))
        for key in ["state", "code_challenge", "redirect_uri", "client_id"] {
            XCTAssertFalse(components.queryItems?.first(where: { $0.name == key })?.value?.isEmpty ?? true, "Missing OAuth field: \(key)")
        }
        await connection.cancelLogin(loginID: login.loginId)
    }

    func testCancelUnblocksLoginWaiter() async throws {
        let fixture = try fixture(mode: "wait")
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        let login = try await connection.beginLogin()
        let waiter = Task { try await connection.waitForLogin(loginID: login.loginId) }
        try await Task.sleep(for: .milliseconds(100))
        await connection.cancelLogin(loginID: login.loginId)
        do { try await waiter.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .stopped) }
    }

    func testManualAuthenticationCodeCompletesWaitingLoginThroughPrivateStdin() async throws {
        let fixture = try fixture(mode: "manual-code")
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        let login = try await connection.beginLogin()
        let waiter = Task { try await connection.waitForLogin(loginID: login.loginId) }
        try await connection.submitLoginCode(code: "  synthetic-code#fixture\n", loginID: login.loginId)
        try await waiter.value
        do { try await connection.submitLoginCode(code: "synthetic-code#fixture", loginID: login.loginId); XCTFail("A completed attempt must reject submissions") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .stopped) }
    }

    func testManualCodeValidationDoesNotConsumeActiveAttempt() async throws {
        let fixture = try fixture(mode: "manual-code")
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        let login = try await connection.beginLogin()
        for code in ["", "synthetic-code", "#fixture", "synthetic-code#", "synthetic-code#fixture#extra", "synthetic\ncode#fixture", String(repeating: "x", count: 8_193) + "#fixture"] {
            do { try await connection.submitLoginCode(code: code, loginID: login.loginId); XCTFail("Expected malformed code rejection") }
            catch { XCTAssertEqual(error as? ClaudeConnectionError, .invalidLoginCode) }
        }
        do { try await connection.submitLoginCode(code: "synthetic-code#other-attempt", loginID: login.loginId); XCTFail("Expected state mismatch") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .loginCodeMismatch) }
        do { try await connection.submitLoginCode(code: "synthetic-code#fixture", loginID: "old-attempt"); XCTFail("Expected attempt mismatch") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .stopped) }
        try await connection.submitLoginCode(code: "synthetic-code#fixture", loginID: login.loginId)
        do { try await connection.submitLoginCode(code: "synthetic-code#fixture", loginID: login.loginId); XCTFail("Expected duplicate rejection") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .loginCodeAlreadySubmitted) }
        try await connection.waitForLogin(loginID: login.loginId)
    }

    func testCanceledLoginCannotReceiveManualCode() async throws {
        let fixture = try fixture(mode: "manual-code")
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        let login = try await connection.beginLogin()
        await connection.cancelLogin(loginID: login.loginId)
        do { try await connection.submitLoginCode(code: "synthetic-code#fixture", loginID: login.loginId); XCTFail("Expected canceled attempt rejection") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .stopped) }
    }

    func testRejectedManualCodeReturnsGenericErrorWithoutProviderDiagnostics() async throws {
        let fixture = try fixture(mode: "manual-code-rejected")
        defer { fixture.remove() }
        let connection = fixture.connection()
        defer { connection.stop() }
        let login = try await connection.beginLogin()
        try await connection.submitLoginCode(code: "synthetic-code#fixture", loginID: login.loginId)
        do { try await connection.waitForLogin(loginID: login.loginId); XCTFail("Expected rejected sign-in") }
        catch {
            XCTAssertEqual(error as? ClaudeConnectionError, .loginFailed)
            XCTAssertFalse(error.localizedDescription.contains("private provider diagnostic"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-code"))
        }
    }

    func testLoginTimeout() async throws {
        let fixture = try fixture(mode: "wait")
        defer { fixture.remove() }
        let connection = fixture.connection(loginTimeout: 0.5)
        defer { connection.stop() }
        let login = try await connection.beginLogin()
        do { try await connection.waitForLogin(loginID: login.loginId); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .timedOut) }
    }

    func testUsageRequestUsesOwnCredentialAndParsesWindows() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let connection = fixture.connection(load: { directory in
            XCTAssertEqual(directory, fixture.root.appendingPathComponent("account-1", isDirectory: true))
            return ClaudeOAuthCredential(accessToken: "fixture", refreshToken: nil, expiresAt: .now.addingTimeInterval(600), scopes: [])
        }, fetch: { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let data = Data(#"{"five_hour":{"utilization":22.5,"resets_at":"2030-01-02T03:04:05.000Z"},"seven_day":{"utilization":40,"resets_at":"2030-01-04T03:04:05Z"},"seven_day_opus":null}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        defer { connection.stop() }
        let limits = try await connection.readLimits()
        XCTAssertEqual(limits.rateLimits.id, "claude")
        XCTAssertEqual(limits.rateLimits.primary?.usedPercent, 22.5)
        XCTAssertEqual(limits.rateLimits.secondary?.windowDurationMins, 10_080)
        XCTAssertNil(limits.rateLimits.credits)
        XCTAssertNil(limits.rateLimitResetCredits)
    }

    func testExpiredCredentialRenewsThroughCLI() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        var loads = 0
        let connection = fixture.connection(load: { _ in
            loads += 1
            return ClaudeOAuthCredential(accessToken: loads == 1 ? "expired-fixture" : "renewed-fixture",
                                         refreshToken: "refresh-fixture", expiresAt: .now.addingTimeInterval(loads == 1 ? -30 : 600), scopes: ["user:profile"])
        }, fetch: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed-fixture")
            return (Data(#"{"five_hour":null,"seven_day":null}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        defer { connection.stop() }
        let limits = try await connection.readLimits()
        XCTAssertEqual(loads, 2)
        XCTAssertNil(limits.rateLimits.secondary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("account-1/renewed").path))
    }

    func testServerFailureCannotSurfacePrivateResponse() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let connection = fixture.connection(load: { _ in
            ClaudeOAuthCredential(accessToken: "fixture", refreshToken: nil, expiresAt: .now.addingTimeInterval(600), scopes: [])
        }, fetch: { request in
            (Data("private-token-content".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        })
        defer { connection.stop() }
        do { _ = try await connection.readLimits(); XCTFail("Expected HTTP failure") }
        catch {
            XCTAssertEqual(error as? ClaudeConnectionError, .http(429))
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }

    func testExpiredCredentialWithoutRenewalIsNeverSent() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let connection = fixture.connection(load: { _ in
            ClaudeOAuthCredential(accessToken: "expired-fixture", refreshToken: nil, expiresAt: .now.addingTimeInterval(-1), scopes: [])
        }, fetch: { _ in
            XCTFail("An expired credential must not reach the usage endpoint")
            throw ClaudeConnectionError.network
        })
        defer { connection.stop() }
        do { _ = try await connection.readLimits(); XCTFail("Expected sign-in required") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .signInRequired) }
    }

    func testStoppedConnectionDiscardsInFlightUsageResponse() async throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        var started = false
        let connection = fixture.connection(load: { _ in
            ClaudeOAuthCredential(accessToken: "fixture", refreshToken: nil, expiresAt: .now.addingTimeInterval(600), scopes: [])
        }, fetch: { request in
            started = true
            try await Task.sleep(for: .milliseconds(100))
            return (Data(#"{"seven_day":{"utilization":0}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let pending = Task { try await connection.readLimits() }
        while !started { try await Task.sleep(for: .milliseconds(5)) }
        connection.stop()
        do { _ = try await pending.value; XCTFail("Expected stopped connection") }
        catch { XCTAssertEqual(error as? ClaudeConnectionError, .stopped) }
    }

    func testMissingWindowsAreUnknownAndMalformedPercentRejected() throws {
        let missing = try ClaudeUsageParser.parse(Data(#"{"five_hour":null,"seven_day":null}"#.utf8))
        XCTAssertNil(missing.rateLimits.primary)
        XCTAssertNil(missing.rateLimits.secondary)
        for value in [#"{"seven_day":{"utilization":-2}}"#,
                      #"{"seven_day":{"utilization":12,"resets_at":"tomorrow"}}"#,
                      #"{"seven_day":{"utilization":"12"}}"#] {
            XCTAssertThrowsError(try ClaudeUsageParser.parse(Data(value.utf8)))
        }
        let noReset = try ClaudeUsageParser.parse(Data(#"{"seven_day":{"utilization":0}}"#.utf8))
        XCTAssertNil(noReset.rateLimits.secondary?.resetDate)
    }

    func testEnvironmentRemovesOverridesAndKeepsPrivateConfig() {
        let directory = URL(fileURLWithPath: "/app/account-1")
        let env = ClaudeConnection.isolatedEnvironment(executableURL: URL(fileURLWithPath: "/bin/claude"), accountDirectory: directory,
                inherited: ["HOME": "/Users/fixture", "CLAUDE_CONFIG_DIR": "/normal", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "",
                            "CLAUDE_CODE_OAUTH_TOKEN": "fixture", "ANTHROPIC_API_KEY": "fixture", "ANTHROPIC_BASE_URL": "https://evil.invalid",
                            "USE_STAGING_OAUTH": "1", "NODE_OPTIONS": "--require unsafe.js"])
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], directory.path)
        XCTAssertEqual(env["HOME"], "/Users/fixture")
        for name in ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "USE_STAGING_OAUTH", "NODE_OPTIONS"] {
            XCTAssertNil(env[name])
        }
    }

    func testLoginHostsAndKeychainScopes() {
        XCTAssertNotNil(ClaudeConnection.validatedLoginURL("https://claude.ai/oauth/authorize?state=fixture"))
        XCTAssertNotNil(ClaudeConnection.validatedLoginURL("https://claude.com/cai/oauth/authorize?state=fixture"))
        for raw in ["http://claude.ai/login", "https://claude.ai.evil.test/login", "https://user@claude.ai/login", "https://claude.ai:8080/login",
                    "https://claude.com.evil.test/cai/oauth/authorize", "https://evilclaude.com/cai/oauth/authorize"] {
            XCTAssertNil(ClaudeConnection.validatedLoginURL(raw))
        }
        let first = ClaudeConnection.keychainService(for: URL(fileURLWithPath: "/app/account-1"))
        let second = ClaudeConnection.keychainService(for: URL(fileURLWithPath: "/app/account-2"))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("Claude Code-credentials-"))
        XCTAssertNotEqual(first, "Claude Code-credentials")
    }
}
