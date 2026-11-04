import Foundation
import XCTest
@testable import CodexUsageViewerCore

@MainActor
final class GitHubUpdateCheckerTests: XCTestCase {
    private let endpoint = URL(string: "https://api.github.com/repos/schneidermayer/claude-and-codex-usage-viewer/releases/latest")!

    private func payload(tag: String = "2.3.1", draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "html_url": "https://untrusted.example/download"
        ])
    }

    private func response(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func checker(current: String, tag: String) throws -> GitHubUpdateChecker {
        let data = try payload(tag: tag)
        let response = response()
        return GitHubUpdateChecker(currentVersion: current, transport: { _ in (data, response) })
    }

    private func assertFailed(_ checker: GitHubUpdateChecker, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(let message) = checker.state else {
            return XCTFail("Expected failed, got \(checker.state)", file: file, line: line)
        }
        XCTAssertFalse(message.isEmpty, file: file, line: line)
    }

    func testNewerPatchAndMultiDigitVersionsAreAvailable() async throws {
        for (current, latest) in [("2.3", "2.3.1"), ("2.9", "2.10"), ("2.3.9", "2.3.10"), ("2.99", "3.0")] {
            let checker = try checker(current: current, tag: latest)
            await checker.check()
            XCTAssertEqual(checker.state, .available(.init(
                version: latest,
                url: URL(string: "https://github.com/schneidermayer/claude-and-codex-usage-viewer/releases/tag/\(latest)")!)))
        }
    }

    func testEqualAndOlderReleasesDoNotOfferDowngrades() async throws {
        for (current, latest) in [("2.3", "2.3"), ("2.3", "2.3.0"), ("2.3.0", "2.3"), ("2.3.1", "2.3"), ("2.10", "2.9")] {
            let checker = try checker(current: current, tag: latest)
            await checker.check()
            XCTAssertEqual(checker.state, .upToDate, "\(current) compared with \(latest)")
        }
    }

    func testDevelopmentCommitSuffixUsesTheBaseReleaseVersion() async throws {
        let older = try checker(current: "2.3-12", tag: "2.3.1")
        await older.check()
        guard case .available(let release) = older.state else { return XCTFail("Expected newer patch") }
        XCTAssertEqual(release.version, "2.3.1")

        let same = try checker(current: "2.3.1-2", tag: "2.3.1")
        await same.check()
        XCTAssertEqual(same.state, .upToDate)
    }

    func testOptionalVPrefixAndConstructedLinkIgnoreResponseURL() async throws {
        let checker = try checker(current: "2.3", tag: "v2.3.1")
        await checker.check()
        XCTAssertEqual(checker.state, .available(.init(
            version: "2.3.1",
            url: URL(string: "https://github.com/schneidermayer/claude-and-codex-usage-viewer/releases/tag/v2.3.1")!)))
    }

    func testMalformedAndUnstableReleaseTagsFail() async throws {
        for tag in ["", "2", "2.3.1.4", "2..3", "2.3-beta", "2.3-1", " 2.3", "2.3/other", "2.3?x=1", "２.３", "2.99999999999999999999999999999"] {
            let checker = try checker(current: "2.3", tag: tag)
            await checker.check()
            assertFailed(checker)
        }
    }

    func testDraftPrereleaseAndMalformedPayloadsFail() async throws {
        let invalidBodies = [
            try payload(draft: true), try payload(prerelease: true),
            Data("{\"tag_name\":\"2.3.1\"}".utf8), Data("not json".utf8)
        ]
        for data in invalidBodies {
            let response = response()
            let checker = GitHubUpdateChecker(currentVersion: "2.3", transport: { _ in (data, response) })
            await checker.check()
            assertFailed(checker)
        }
    }

    func testInvalidInstalledVersionsFailWithoutMakingRequest() async {
        for current in ["Development", "2.3-beta", "2.3-", "2.3-1-2", "2.3+metadata", ""] {
            let checker = GitHubUpdateChecker(currentVersion: current, transport: { _ in
                XCTFail("An unknown current version cannot be compared")
                throw URLError(.badURL)
            })
            await checker.check()
            assertFailed(checker)
        }
    }

    func testHTTPFailuresAreNeverReportedAsUpToDate() async throws {
        let data = try payload()
        for status in [304, 403, 404, 429, 500] {
            let response = response(status: status)
            let checker = GitHubUpdateChecker(currentVersion: "2.3", transport: { _ in (data, response) })
            await checker.check()
            assertFailed(checker)
        }
    }

    func testNetworkAndNonHTTPResponsesFail() async throws {
        let offline = GitHubUpdateChecker(currentVersion: "2.3", transport: { _ in throw URLError(.notConnectedToInternet) })
        await offline.check()
        assertFailed(offline)

        let data = try payload()
        let response = URLResponse(url: endpoint, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        let nonHTTP = GitHubUpdateChecker(currentVersion: "2.3", transport: { _ in (data, response) })
        await nonHTTP.check()
        assertFailed(nonHTTP)
    }

    func testAutomaticCheckRunsOnceAndExplicitCheckRetries() async throws {
        var requests: [URLRequest] = []
        let data = try payload()
        let response = response()
        let checker = GitHubUpdateChecker(currentVersion: "2.3", transport: { request in
            requests.append(request)
            if requests.count == 1 { throw URLError(.timedOut) }
            return (data, response)
        })
        await checker.check()
        assertFailed(checker)
        await checker.check()
        XCTAssertEqual(requests.count, 1)
        await checker.check(force: true)
        XCTAssertEqual(requests.count, 2)
        guard case .available = checker.state else { return XCTFail("Retry should find the release") }
        await checker.check()
        XCTAssertEqual(requests.count, 2)
    }

    func testRequestUsesPublicEndpointAndBoundedTimeout() async throws {
        let data = try payload()
        let response = response()
        let checker = GitHubUpdateChecker(currentVersion: "2.3", transport: { request in
            XCTAssertEqual(request.url, self.endpoint)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
            return (data, response)
        })
        await checker.check()
    }

    func testConcurrentChecksShareOneRequest() async throws {
        let sent = expectation(description: "request started")
        let data = try payload()
        let response = response()
        var calls = 0
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        let checker = GitHubUpdateChecker(currentVersion: "2.3", transport: { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { pending in
                continuation = pending
                sent.fulfill()
            }
        })
        let first = Task { await checker.check() }
        await fulfillment(of: [sent], timeout: 1)
        XCTAssertEqual(checker.state, .checking)
        await checker.check(force: true)
        await checker.check()
        XCTAssertEqual(calls, 1)
        continuation?.resume(returning: (data, response))
        await first.value
        guard case .available = checker.state else { return XCTFail("Expected available result") }
    }
}
