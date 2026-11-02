import XCTest
@testable import CodexUsageViewerCore

final class SnapshotStoreTests: XCTestCase {
    func testResetCreditSnapshotRoundTripKeepsOnlyCountAndExpiryAndReadsLegacySnapshots() throws {
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":4,"credits":[{"id":"redemption-secret","status":"available","expiresAt":1900000500,"grantedAt":1900000000,"title":"Unneeded title","description":"Unneeded description"}]}}"#.utf8))
        var snapshot = UsageSnapshot.preview
        snapshot.accounts[0].resetCredits = response.rateLimitResetCredits
        let data = try JSONEncoder().encode(snapshot)
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(serialized.contains("redemption-secret"))
        XCTAssertFalse(serialized.contains("grantedAt"))
        XCTAssertFalse(serialized.contains("Unneeded"))
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(decoded.accounts[0].resetCredits, RateLimitResetCredits(availableCount: 4, earliestExpiresAt: 1_900_000_500))
        XCTAssertEqual(decoded.accounts[0].primaryBucket?.credits, snapshot.accounts[0].primaryBucket?.credits)
        let legacy = try JSONDecoder().decode(AccountSnapshot.self, from: Data(#"{"id":"account-1","name":"Account","state":"connected","buckets":[],"updatedAt":0}"#.utf8))
        XCTAssertNil(legacy.resetCredits)
        XCTAssertEqual(legacy.resetsValue(at: Date(timeIntervalSinceReferenceDate: 0)), .unknown)
    }

    func testSnapshotPublicationIsPrivateAndReplacesWholeFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        try SharedSnapshotStore.write(.preview, to: file)
        try SharedSnapshotStore.write(.empty, to: file)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(snapshot.accounts.count, 1)
        XCTAssertTrue(snapshot.accounts.allSatisfy { $0.state == .disconnected && $0.buckets.isEmpty })
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["snapshot.json"])
    }

    func testLegacySnapshotRetainsAllSlotsAndDefaultsToCodex() throws {
        let data = Data(#"{"version":1,"accounts":[{"id":"account-2","name":"Account 2","email":"legacy@fixture.test","state":"connected","buckets":[]}],"savedAt":0}"#.utf8)
        let migrated = SharedSnapshotStore.normalized(try JSONDecoder().decode(UsageSnapshot.self, from: data))
        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.accounts.count, 3)
        XCTAssertEqual(migrated.accounts.first?.email, "legacy@fixture.test")
        XCTAssertTrue(migrated.accounts.allSatisfy { $0.provider == .codex })
    }

    func testDynamicSnapshotKeepsOrderAndDoesNotReintroduceRemovedSlots() throws {
        let accounts = [AccountSnapshot(id: "account-3", name: "Account", provider: .claude),
                        AccountSnapshot(id: "account-1", name: "Account", provider: .codex)]
        let original = UsageSnapshot(accounts: accounts, savedAt: .now)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(SharedSnapshotStore.normalized(decoded).accounts, accounts)
        var invalid = decoded
        invalid.accounts += [accounts[0], AccountSnapshot(id: "../invalid", name: "Invalid")]
        XCTAssertEqual(SharedSnapshotStore.normalized(invalid).accounts, accounts)
        invalid.accounts = []
        XCTAssertEqual(SharedSnapshotStore.normalized(invalid).accounts.count, 1)
    }

    func testClaudePlanAndLocalIdentityRemainProviderSpecific() {
        var claude = AccountSnapshot(id: "account-1", name: "Account", email: "same@fixture.test", plan: "Pro", state: .connected, provider: .claude)
        XCTAssertEqual(claude.subscriptionDisplayName, "Pro")
        let now = Date.now
        let snapshot = UsageSnapshot(accounts: [claude], savedAt: now, localCodexEmail: claude.email, localCodexCheckedAt: now)
        XCTAssertFalse(snapshot.isLocalAccount(claude, at: now))
        claude.provider = .codex
        XCTAssertEqual(claude.subscriptionDisplayName, "200")
        XCTAssertTrue(snapshot.isLocalAccount(claude, at: now))
    }
}
