import AppKit
import SwiftUI
import ServiceManagement

struct CodexUsageViewerSettingsView: View {
    @ObservedObject var store: CodexUsageViewerStore
    @Environment(\.dismiss) private var dismiss
    @State private var executablePath = ""
    @State private var claudeExecutablePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 11) {
                CodexUsageViewerMark(size: 37)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.65)
                    Text("Claude and Codex Usage Viewer · Version \(CodexUsageViewerVersion.display)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the command-line apps used for your private account connections.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                connection(provider: .claude, path: $claudeExecutablePath, available: store.availableClaude)
                Divider()
                connection(provider: .codex, path: $executablePath, available: store.availableCodex)
            }
            .padding(18)
            .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 15) {
                detail(symbol: "arrow.clockwise", title: "Background updates", text: "A small helper checks connected accounts every three minutes, even after you quit the app. It starts when you log in and has no Dock or menu bar icon. macOS chooses when widgets refresh.")
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.backgroundStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("codexusageviewer.settings.backgroundStatus")
                    HStack {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .accessibilityIdentifier("codexusageviewer.settings.loginItems")
                        if !store.backgroundNeedsApproval && !store.backgroundConnected {
                            Button("Retry") { Task { await store.retryBackgroundService() } }
                                .accessibilityIdentifier("codexusageviewer.settings.retryBackground")
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                .padding(.leading, 34)
                detail(symbol: "lock.shield", title: "Private account connections", text: "Each account has its own connection on this Mac. Your widget receives usage snapshots; it never receives sign-in credentials.")
                detail(symbol: "clock", title: "Last reported usage", text: "Usage shows the last successful update. A reset countdown never assumes that a limit has recovered.")
            }

            HStack {
                Text("Version \(CodexUsageViewerVersion.display)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") {
                    if executablePath != store.codexPath { store.codexPath = executablePath }
                    if claudeExecutablePath != store.claudePath { store.claudePath = claudeExecutablePath }
                    dismiss()
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("codexusageviewer.settings.done")
            }
        }
        .padding(28)
        .frame(width: 540)
        .onAppear {
            executablePath = store.codexPath
            claudeExecutablePath = store.claudePath
        }
        .onExitCommand { dismiss() }
    }

    private func detail(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connection(provider: AccountProvider, path: Binding<String>, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(provider.displayName) connection").font(.system(size: 13, weight: .semibold))
                Spacer()
                Label(available ? "Ready" : "Setup needed", systemImage: available ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(available ? CodexUsageViewerPalette.mint : .orange)
            }
            HStack {
                TextField("Automatic detection", text: path)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(provider.displayName) executable path")
                    .accessibilityIdentifier(provider == .codex ? "codexusageviewer.settings.executable" : "codexusageviewer.settings.claudeExecutable")
                    .onSubmit { applyPath(path.wrappedValue, provider: provider) }
                Button("Choose…") { chooseExecutable(provider: provider) }
            }
            HStack {
                Button("Use automatic detection") {
                    path.wrappedValue = ""
                    applyPath("", provider: provider)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                Spacer()
                if path.wrappedValue != (provider == .codex ? store.codexPath : store.claudePath) {
                    Button("Apply") { applyPath(path.wrappedValue, provider: provider) }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private func applyPath(_ path: String, provider: AccountProvider) {
        if provider == .codex { store.codexPath = path }
        else { store.claudePath = path }
    }

    private func chooseExecutable(provider: AccountProvider) {
        let panel = NSOpenPanel()
        panel.title = "Choose the \(provider.displayName) executable"
        panel.message = "Select the \(provider.displayName) command-line executable installed on this Mac."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            if provider == .codex { executablePath = url.path }
            else { claudeExecutablePath = url.path }
            applyPath(url.path, provider: provider)
        }
    }
}
