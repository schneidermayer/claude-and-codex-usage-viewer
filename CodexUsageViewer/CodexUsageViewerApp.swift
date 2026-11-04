import AppKit
import SwiftUI
import WidgetKit

@main
enum CodexUsageViewerMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-for-updates") {
            // Use the same check as the app without starting account connections.
            Task { @MainActor in
                let checker = GitHubUpdateChecker()
                await checker.check(force: true)
                var result = ["installedVersion": CodexUsageViewerVersion.display]
                var succeeded = true
                switch checker.state {
                case .available(let release):
                    result["status"] = "updateAvailable"
                    result["latestVersion"] = release.version
                    result["releaseURL"] = release.url.absoluteString
                case .upToDate:
                    result["status"] = "upToDate"
                case .failed(let message):
                    result["status"] = "failed"
                    result["message"] = message
                    succeeded = false
                case .idle, .checking:
                    result["status"] = "failed"
                    succeeded = false
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--reload-widgets") {
            // WidgetKit requires the app executable; reload without starting SwiftUI or workers.
            WidgetCenter.shared.reloadAllTimelines()
            WidgetCenter.shared.getCurrentConfigurations { _ in exit(EXIT_SUCCESS) }
            RunLoop.main.run(until: Date.now.addingTimeInterval(5))
            return
        }
        CodexUsageViewerApp.main()
    }
}

struct CodexUsageViewerApp: App {
    @NSApplicationDelegateAdaptor(CodexUsageViewerAppDelegate.self) private var appDelegate
    @StateObject private var store = CodexUsageViewerStore()
    @StateObject private var updateChecker = GitHubUpdateChecker()
    @State private var showsUpdateResult = false

    var body: some Scene {
        Window("Claude and Codex Usage Viewer", id: "dashboard") {
            DashboardHost(store: store)
                .environmentObject(updateChecker)
                .onAppear { appDelegate.store = store }
                .task { await updateChecker.check() }
                .alert("App Updates", isPresented: $showsUpdateResult) {
                    if case .available(let release) = updateChecker.state {
                        Button("View Release") { NSWorkspace.shared.open(release.url) }
                    }
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(updateChecker.state.message)
                }
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Claude and Codex Usage Viewer \(CodexUsageViewerVersion.display)") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Claude and Codex Usage Viewer") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: CodexUsageViewerVersion.display])
                }
                Button("Check for Updates…") {
                    store.openDashboard()
                    Task {
                        await updateChecker.check(force: true)
                        showsUpdateResult = true
                    }
                }
                .disabled(updateChecker.state == .checking)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Usage") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(store.isRefreshing || store.isDemo)
            }
        }

        Settings {
            CodexUsageViewerSettingsView(store: store)
                .environmentObject(updateChecker)
        }
    }
}

private struct DashboardHost: View {
    @ObservedObject var store: CodexUsageViewerStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        DashboardView(store: store)
            .frame(minWidth: 900, minHeight: 620)
            .onAppear { store.openDashboardAction = { openWindow(id: "dashboard") } }
            .onOpenURL { _ in store.openDashboard() }
    }
}

@MainActor
final class CodexUsageViewerAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: CodexUsageViewerStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
}
