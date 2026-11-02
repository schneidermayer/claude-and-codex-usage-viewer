import Foundation
import Darwin

enum SharedSnapshotStore {
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CodexUsageViewerConstants.appGroup)?
            .appendingPathComponent("usage-snapshot.json")
    }

    static func load() -> UsageSnapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else { return .empty }
        return normalized(snapshot)
    }

    static func normalized(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        guard [1, 2].contains(snapshot.version) else { return .empty }
        var safe = snapshot
        safe.version = 2
        var seen = Set<String>()
        safe.accounts = snapshot.accounts.filter {
            CodexUsageViewerConstants.accountIDs.contains($0.id) && seen.insert($0.id).inserted
        }
        if snapshot.version == 1 {
            // Preserve all legacy slots, including app-owned sign-ins without cached usage.
            for account in AccountSnapshot.emptyAccounts where !seen.contains(account.id) {
                safe.accounts.append(account)
            }
        }
        if safe.accounts.isEmpty { safe.accounts = UsageSnapshot.empty.accounts }
        return safe
    }

    static func save(_ snapshot: UsageSnapshot) throws {
        guard let url = fileURL else {
            throw NSError(domain: "CodexUsageViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude and Codex Usage Viewer couldn’t access its widget storage. Check the app’s signing and App Group configuration."])
        }
        try write(snapshot, to: url)
    }

    static func write(_ snapshot: UsageSnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
        let manager = FileManager.default
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        // Atomically publish the already-private file.
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
