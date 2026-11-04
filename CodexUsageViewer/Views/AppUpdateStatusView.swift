import SwiftUI

struct AppUpdateStatusView: View {
    @ObservedObject var checker: GitHubUpdateChecker

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App updates")
                    .font(.system(size: 12, weight: .medium))
                Text(checker.state.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("codexusageviewer.updateStatus")
                if case .available(let release) = checker.state {
                    Link("View release on GitHub", destination: release.url)
                        .font(.system(size: 11))
                }
            }
            Spacer(minLength: 0)
            Button("Check for Updates") {
                Task { await checker.check(force: true) }
            }
            .disabled(checker.state == .checking)
            .accessibilityIdentifier("codexusageviewer.checkForUpdates")
        }
    }
}

extension GitHubUpdateChecker.State {
    var message: String {
        switch self {
        case .idle: return "Checks GitHub when the app opens."
        case .checking: return "Checking GitHub…"
        case .upToDate: return "You’re up to date."
        case .available(let release): return "Version \(release.version) is available."
        case .failed(let message): return message
        }
    }
}
