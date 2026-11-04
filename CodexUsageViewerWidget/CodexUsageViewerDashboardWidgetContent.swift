import SwiftUI
import WidgetKit

/// Tall account columns devote the available height to bottom-up quota fills.
struct CodexUsageViewerDashboardWidgetContent: View {
    let snapshot: UsageSnapshot
    var referenceDate: Date = .now

    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    private var accounts: [AccountSnapshot] { Array(snapshot.accounts.prefix(3)) }
    private var dense: Bool { accounts.count == 3 }
    private var showsResources: Bool { accounts.contains { $0.provider == .codex } }
    private var showsExpiry: Bool { accounts.contains { resetExpiry($0) != nil } }
    private var footerHeight: CGFloat { 24 + (showsResources ? 26 : 0) + (showsExpiry ? 24 : 0) }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 6
            let count = max(1, accounts.count)
            let width = max(0, (geometry.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
            HStack(alignment: .top, spacing: spacing) {
                ForEach(accounts) { account in
                    Link(destination: URL(string: "codexusageviewer://account/\(account.id)")!) {
                        accountCard(account, height: geometry.size.height)
                    }
                    .buttonStyle(.plain)
                    .frame(width: width, height: geometry.size.height)
                }
            }
        }
        .padding(8)
        .fontDesign(.rounded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude and Codex usage remaining and time until reset")
    }

    private func accountCard(_ account: AccountSnapshot, height: CGFloat) -> some View {
        let color = accent(for: account)
        let windows = [account.fiveHourWindow, account.weeklyWindow].compactMap { $0 }
        let usageHeight = max(0, height - 12 - 50 - 16 - footerHeight)
        let panelCount = max(1, windows.count)
        let panelHeight = max(0, (usageHeight - CGFloat(panelCount - 1) * 6) / CGFloat(panelCount))
        return VStack(alignment: .leading, spacing: 0) {
            identity(account, color: color)
                .frame(height: 50)
                .padding(.bottom, 8)

            VStack(spacing: 6) {
                if windows.isEmpty {
                    quotaPanel(account, window: nil, color: color, paired: false)
                        .frame(height: panelHeight)
                } else {
                    ForEach(windows, id: \.windowDurationMins) { window in
                        quotaPanel(account, window: window, color: color, paired: windows.count > 1)
                            .frame(height: panelHeight)
                    }
                }
            }
            .frame(height: usageHeight)

            accountFooter(account)
                .frame(height: footerHeight, alignment: .topLeading)
                .padding(.top, 8)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // Include the identity in the first limit's background and the
            // footer in the last. The split sits between the two quota rows.
            accountBackground(account, windows: windows, color: color,
                              splitY: 6 + 50 + 8 + panelHeight + 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func identity(_ account: AccountSnapshot, color: Color) -> some View {
        let email = account.email ?? ""
        let emailFallback = !email.isEmpty && account.displayName == email
        return VStack(alignment: .leading, spacing: 4) {
            Text(account.displayName)
                .font(.system(size: dense ? 12 : 15, weight: .semibold))
                .lineLimit(emailFallback ? 1 : 2)
                .truncationMode(emailFallback ? .middle : .tail)
                .minimumScaleFactor(0.85)
                .frame(height: 28, alignment: .center)
                .accessibilityLabel(emailFallback || email.isEmpty ? account.displayName : "\(account.displayName), \(email)")
                .help(emailFallback || email.isEmpty ? account.displayName : "\(account.displayName)\n\(email)")
            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    CodexUsageViewerProviderMark(provider: account.provider)
                        .fill(Color.primary)
                        .frame(width: 11, height: 11)
                        .accessibilityHidden(true)
                    Text(account.subscriptionDisplayName ?? "—")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color.opacity(0.13), in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(account.provider.displayName), subscription plan: \(account.subscriptionDisplayName ?? "Unknown plan")")
                .help("\(account.provider.displayName), subscription plan: \(account.subscriptionDisplayName ?? "Unknown plan")")

                if snapshot.isLocalAccount(account, at: referenceDate) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .widgetAccentable()
                        .accessibilityLabel("Logged In")
                        .help("Currently signed in to local \(account.provider.displayName)")
                }
            }
            .frame(height: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaPanel(_ account: AccountSnapshot, window: QuotaWindow?, color: Color,
                            paired: Bool) -> some View {
        let state = account.usage(for: window, at: referenceDate)
        let reset = state.window.flatMap { QuotaResetProgress(window: $0, at: referenceDate) }
        let label = window?.label ?? "Usage"
        let description = state.window.map { "\(label): \($0.remainingPercent) percent remaining" }
            ?? "\(label) usage unknown. \(state.status ?? "")"
        let resetDescription = reset.map { "Reset in \($0.countdown)" } ?? (state.status ?? "Reset time not reported")
        return VStack(spacing: 0) {
            Text(label)
                .font(.system(size: dense ? 10 : 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            percentage(state, color: color, paired: paired)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                if reset != nil {
                    Text("Resets in")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(reset?.countdown ?? resetStatus(state))
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: dense ? 8 : 10))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.bottom, 4)
            CodexUsageViewerResetTrack(fractionRemaining: reset?.fractionRemaining, accent: color,
                                      segments: window?.windowDurationMins == 300 ? 5 : 7,
                                      height: 4, spacing: 2, widgetAccentable: true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(description). \(resetDescription)")
        .help("\(description). \(resetDescription)")
    }

    private func accountBackground(_ account: AccountSnapshot, windows: [QuotaWindow],
                                   color: Color, splitY: CGFloat) -> some View {
        GeometryReader { geometry in
            let first = account.usage(for: windows.first, at: referenceDate).window?.remainingPercent
            Group {
                if windows.count == 2 {
                    let boundary = min(geometry.size.height, max(0, splitY))
                    VStack(spacing: 0) {
                        usageFill(remaining: first, color: color)
                            .frame(height: boundary)
                        usageFill(remaining: account.usage(for: windows[1], at: referenceDate).window?.remainingPercent,
                                  color: color)
                            .frame(height: max(0, geometry.size.height - boundary))
                            .overlay(alignment: .top) {
                                Color.primary.opacity(0.08).frame(height: 0.5)
                            }
                    }
                } else {
                    usageFill(remaining: first, color: color)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func usageFill(remaining: Int?, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                color.opacity(colorScheme == .dark ? 0.055 : 0.05)
                if let remaining, remaining > 0 {
                    color.opacity(colorScheme == .dark ? 0.14 : 0.12)
                        .frame(height: geometry.size.height * CGFloat(remaining) / 100)
                        .overlay(alignment: .top) {
                            if remaining < 100 {
                                color.opacity(colorScheme == .dark ? 0.24 : 0.18)
                                    .frame(height: 0.5)
                            }
                        }
                }
            }
            .widgetAccentable()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func percentage(_ state: QuotaUsageState, color: Color, paired: Bool) -> some View {
        let value = state.window.map { String($0.remainingPercent) } ?? "—"
        let suffix = state.window == nil ? "" : "%"
        let size: CGFloat = paired ? (dense ? 30 : 36) : (dense ? 42 : 48)
        return Text("\(Text(value).font(.system(size: size, weight: .medium)))\(Text(suffix).font(.system(size: paired ? 14 : 18, weight: .medium)))")
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(state.window == nil ? Color.secondary : color)
            .widgetAccentable()
    }

    private func accountFooter(_ account: AccountSnapshot) -> some View {
        let window = account.weeklyWindow ?? account.fiveHourWindow
        let date = account.usage(for: window, at: referenceDate).window?.resetDate
        return VStack(alignment: .leading, spacing: 4) {
            dateDetails(date, label: "\(window?.label ?? "Usage") reset")
                .frame(height: 24)
            if showsResources {
                Group {
                    if account.provider == .codex {
                        VStack(spacing: 4) {
                            Divider().overlay(.primary.opacity(0.04))
                            HStack(spacing: 4) {
                                resource(account.creditsValue(at: referenceDate), symbol: "c.circle",
                                         label: "Available credits")
                                Spacer(minLength: 0)
                                resource(account.resetsValue(at: referenceDate), symbol: "arrow.counterclockwise",
                                         label: "Available usage resets")
                            }
                        }
                    } else {
                        Color.clear.accessibilityHidden(true)
                    }
                }
                .frame(height: 22)
            }
            if showsExpiry {
                Group {
                    if let expiry = resetExpiry(account) {
                        dateDetails(expiry, label: "Next usage reset expires", expiry: true)
                    } else {
                        Color.clear.accessibilityHidden(true)
                    }
                }
                .frame(height: 20)
            }
        }
    }

    private func dateDetails(_ date: Date?, label: String, expiry: Bool = false) -> some View {
        let description = "\(label): \(date?.formatted(date: .complete, time: .shortened) ?? "unavailable")"
        return VStack(alignment: .leading, spacing: 0) {
            if let date {
                Text(expiry ? "Expires \(date.formatted(.dateTime.month(.abbreviated).day()))"
                            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                Text(date, format: .dateTime.hour().minute())
                    .monospacedDigit()
            } else {
                Text("Reset unavailable")
            }
        }
        .font(.system(size: expiry ? 8 : 9))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .help(description)
    }

    private func resetExpiry(_ account: AccountSnapshot) -> Date? {
        guard account.provider == .codex, account.resetsValue(at: referenceDate) != .unknown,
              let count = account.resetCredits?.availableCount, count > 0 else { return nil }
        return account.resetCredits?.expiryDate
    }

    private func resource(_ value: AccountResourceValue, symbol: String, label: String) -> some View {
        Text("\(Image(systemName: symbol)) \(resourceText(value))")
            .font(.system(size: dense ? 10 : 12, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .accessibilityLabel("\(label): \(value.accessibilityText)")
            .help("\(label): \(value.accessibilityText)")
    }

    private func resourceText(_ value: AccountResourceValue) -> String {
        let text = dense ? value.shortText : value.compactText
        let parts = text.split(separator: "E")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
        let mantissa = parts[0].hasSuffix(".0") ? String(parts[0].dropLast(2)) : String(parts[0])
        return "\(mantissa)e\(exponent)"
    }

    private func resetStatus(_ state: QuotaUsageState) -> String {
        switch state {
        case .available, .notReported: return "—"
        case .disconnected: return "Connect"
        case .needsSignIn: return "Sign in"
        case .waiting: return "Waiting"
        case .stale: return "Stale"
        case .unavailable: return "Unavailable"
        case .resetElapsed: return "Refresh"
        }
    }

    private func accent(for account: AccountSnapshot) -> Color {
        renderingMode == .accented ? .primary
            : CodexUsageViewerPalette.accent(for: CodexUsageViewerPalette.index(for: account.id))
    }
}
