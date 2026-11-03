import SwiftUI
import WidgetKit

struct CodexUsageViewerWidgetContent: View {
    let snapshot: UsageSnapshot
    var family: WidgetFamily?
    var referenceDate: Date = .now

    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    private var isSmall: Bool { (family ?? environmentFamily) == .systemSmall }
    private var accounts: [AccountSnapshot] {
        Array(snapshot.accounts.prefix(3))
    }
    private var showsBothLimits: Bool {
        accounts.contains { $0.fiveHourWindow != nil } && accounts.contains { $0.weeklyWindow != nil }
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = isSmall ? 4 : 12
            let count = max(1, accounts.count)
            let columnWidth = max(0, (geometry.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
            HStack(spacing: spacing) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    Group {
                        if isSmall {
                            accountColumn(account, index: index)
                        } else {
                            Link(destination: accountURL(account)) {
                                accountColumn(account, index: index)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: columnWidth, height: geometry.size.height)
                }
            }
        }
        .fontDesign(.rounded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude and Codex usage remaining and time until reset")
    }

    private func accountColumn(_ account: AccountSnapshot, index: Int) -> some View {
        let color = accent(CodexUsageViewerPalette.index(for: account.id))
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                if snapshot.isLocalAccount(account, at: referenceDate) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: isSmall ? 7 : 10, weight: .semibold))
                        .foregroundStyle(color)
                        .widgetAccentable()
                        .accessibilityLabel("Logged In")
                }
                Text(widgetName(account))
                    .font(.system(size: isSmall ? 10 : 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(account.displayName)
                    .help(account.displayName)
            }
            .frame(height: showsBothLimits && isSmall ? 14 : 16)

            if isSmall {
                subscription(account, color: color)
                    .padding(.top, 3)
            } else {
                Text(account.provider.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 11)
            }

            if showsBothLimits {
                if !isSmall {
                    subscription(account, color: color)
                        .padding(.top, 2)
                }
                VStack(spacing: 0) {
                    if isSmall {
                        alignedSmallLimits(account, color: color)
                    } else if account.fiveHourWindow != nil && account.weeklyWindow != nil {
                        VStack(spacing: 4) {
                            compactLimit(account, window: account.fiveHourWindow, label: "5h", fullLabel: "5-hour", color: color, segments: 5)
                            compactLimit(account, window: account.weeklyWindow, label: "Weekly", fullLabel: "Weekly", color: color, segments: 7)
                        }
                    } else {
                        singleLimit(account, color: color, compact: true)
                    }
                }
                .frame(height: isSmall ? 79 : 74)
                .padding(.top, isSmall ? 4 : 2)
            } else {
                singleLimit(account, color: color)
            }

            Spacer(minLength: showsBothLimits && !isSmall ? 4 : 5)

            if account.provider != .codex {
                Color.clear.frame(height: isSmall ? 14 : 17)
                    .accessibilityHidden(true)
            } else if isSmall {
                smallResources(account)
                    .frame(height: 14)
            } else {
                HStack(spacing: 3) {
                    credits(account)
                    Spacer(minLength: 0)
                    availableResets(account)
                }
                .frame(height: 17)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isSmall {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(colorScheme == .dark ? 0.045 : 0.03))
                    .padding(.vertical, -5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func alignedSmallLimits(_ account: AccountSnapshot, color: Color) -> some View {
        let hasSession = account.fiveHourWindow != nil
        return VStack(spacing: 6) {
            if hasSession {
                compactLimit(account, window: account.fiveHourWindow, label: "5h", fullLabel: "5-hour",
                             color: color, segments: 5, headlineHeight: 15)
            } else {
                Color.clear.frame(height: 32).accessibilityHidden(true)
            }
            if account.weeklyWindow != nil || !hasSession {
                compactLimit(account, window: account.weeklyWindow, label: "7d", fullLabel: "Weekly",
                             color: color, segments: 7, headlineHeight: 24, prominent: !hasSession)
            } else {
                Color.clear.frame(height: 41).accessibilityHidden(true)
            }
        }
    }

    private func subscription(_ account: AccountSnapshot, color: Color) -> some View {
        HStack(spacing: 3) {
            if isSmall {
                CodexUsageViewerProviderMark(provider: account.provider)
                    .fill(Color.primary)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            Text(account.subscriptionDisplayName ?? "—")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
            .font(.system(size: isSmall || !showsBothLimits ? 9 : 8, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, isSmall ? 4 : 5)
            .padding(.vertical, isSmall ? 2 : 1)
            .background(color.opacity(0.13), in: Capsule())
            .frame(height: isSmall ? 16 : (showsBothLimits ? 12 : 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(account.provider.displayName), subscription plan: \(account.subscriptionDisplayName ?? "Unknown plan")")
            .help("\(account.provider.displayName), subscription plan: \(account.subscriptionDisplayName ?? "Unknown plan")")
    }

    private func compactLimit(_ account: AccountSnapshot, window: QuotaWindow?, label: String,
                              fullLabel: String, color: Color, segments: Int,
                              headlineHeight: CGFloat? = nil, prominent: Bool = false) -> some View {
        let state = account.usage(for: window, at: referenceDate)
        let reset = state.window.flatMap { QuotaResetProgress(window: $0, at: referenceDate) }
        let description = state.window.map { "\(fullLabel): \($0.remainingPercent) percent remaining" }
            ?? "\(fullLabel) usage unknown. \(state.status ?? "")"
        let resetDescription = reset.map { "Reset in \($0.countdown)" } ?? (state.status ?? "Reset time not reported")
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                if !prominent {
                    Text(label)
                        .font(.system(size: isSmall ? 8 : 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(state.window.map { String($0.remainingPercent) } ?? "—")
                        .font(.system(size: prominent ? 19.5 : (isSmall ? 12 : 18), weight: .semibold))
                    if state.window != nil {
                        Text("%")
                            .font(.system(size: prominent ? 9 : (isSmall ? 8 : 11), weight: .medium))
                    }
                }
                .monospacedDigit()
                .foregroundStyle(state.window == nil ? Color.secondary : color)
                .widgetAccentable()
                if prominent { Spacer(minLength: 0) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.bottom) { dimensions in
                headlineHeight == nil ? dimensions[.bottom] : dimensions[.firstTextBaseline]
            }
            .frame(height: headlineHeight.map { $0 - 4 } ?? (isSmall ? 15 : 18),
                   alignment: headlineHeight == nil ? .center : .bottom)
            .padding(.bottom, headlineHeight == nil ? 0 : 4)
            CodexUsageViewerResetTrack(fractionRemaining: reset?.fractionRemaining, accent: color,
                                      segments: segments, height: 3, spacing: isSmall ? 1 : 2,
                                      widgetAccentable: true)
                .padding(.top, 2)
            Text(reset?.countdown ?? compactResetStatus(state))
                .font(.system(size: isSmall ? 8 : 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 11)
                .padding(.top, 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(description). \(resetDescription)")
        .help("\(description). \(resetDescription)")
    }

    private func singleLimit(_ account: AccountSnapshot, color: Color, compact: Bool = false) -> some View {
        let window = account.weeklyWindow ?? account.fiveHourWindow
        let label = window?.label ?? "Weekly"
        let state = account.usage(for: window, at: referenceDate)
        let reset = state.window.flatMap { QuotaResetProgress(window: $0, at: referenceDate) }
        return Group {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(state.window.map { String($0.remainingPercent) } ?? "—")
                    .font(.system(size: isSmall ? 19.5 : 31, weight: .semibold))
                    .monospacedDigit()
                if state.window != nil {
                    Text("%")
                        .font(.system(size: isSmall ? 9 : 13, weight: .medium))
                }
            }
            .foregroundStyle(state.window == nil ? Color.secondary : color)
            .widgetAccentable()
            .fixedSize()
            .frame(height: isSmall ? 30 : 36)
            .padding(.top, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.window.map { "\($0.remainingPercent) percent \(label.lowercased()) usage remaining" } ?? "\(label) usage unknown")

            if !isSmall || window?.windowDurationMins == 300 {
                Text(window?.windowDurationMins == 300 ? "5h" : "Weekly")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 10)
            }

            Spacer(minLength: 0)

            if !compact && !isSmall { subscription(account, color: color) }

            if state.window != nil {
                CodexUsageViewerResetTrack(fractionRemaining: reset?.fractionRemaining,
                                          accent: color, segments: window?.windowDurationMins == 300 ? 5 : 7,
                                          height: compact ? 3 : 4, spacing: isSmall ? 1 : 3,
                                          widgetAccentable: true)
                    .padding(.top, compact ? 2 : 5)
                Text(reset?.countdown ?? "—")
                    .font(.system(size: isSmall ? 9 : 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: compact ? 11 : 14)
                    .padding(.top, compact ? 1 : 3)
                    .accessibilityLabel(reset.map { "\(label) reset in \($0.countdown)" } ?? "Reset time not reported")
                    .help(reset.map { "\(label) reset in \($0.countdown)" } ?? "Reset time not reported")
            } else {
                Text(compactStatus(state))
                    .font(.system(size: isSmall ? 9 : 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(height: compact ? 17 : 26)
                    .accessibilityLabel(state.status ?? "Usage unknown")
                    .help(state.status ?? "Usage unknown")
            }

        }
    }

    private func smallResources(_ account: AccountSnapshot) -> some View {
        let credits = account.creditsValue(at: referenceDate)
        let resets = account.resetsValue(at: referenceDate)
        let description = "Available credits: \(credits.accessibilityText). Available usage resets: \(resets.accessibilityText)"
        let row = Text("\(Image(systemName: "c.circle")) \(compactResourceText(credits))  \(Image(systemName: "arrow.counterclockwise")) \(compactResourceText(resets))")
        // Size symbols and digits together; Text's minimumScaleFactor does not
        // reliably shrink interpolated symbols in a narrow widget column.
        return ViewThatFits(in: .horizontal) {
            row.font(.system(size: 8, weight: .medium)).fixedSize()
            row.font(.system(size: 7, weight: .medium)).fixedSize()
            row.font(.system(size: 6, weight: .medium)).fixedSize()
            row.font(.system(size: 5, weight: .medium)).fixedSize()
        }
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
            .help(description)
    }

    private func credits(_ account: AccountSnapshot) -> some View {
        resource(account.creditsValue(at: referenceDate), symbol: "c.circle", alignment: isSmall ? .center : .leading,
                 label: "Available credits", help: "Credits available for additional usage")
    }

    private func availableResets(_ account: AccountSnapshot) -> some View {
        resource(account.resetsValue(at: referenceDate), symbol: "arrow.counterclockwise", alignment: isSmall ? .center : .trailing,
                 label: "Available usage resets", help: "Earned usage resets available to use")
    }

    private func resource(_ value: AccountResourceValue, symbol: String, alignment: Alignment,
                          label: String, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: isSmall ? 9 : 10, weight: .medium))
                .accessibilityHidden(true)
            Text(compactResourceText(value))
                .font(.system(size: isSmall ? 9 : 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value.accessibilityText)")
        .help("\(help): \(value.accessibilityText)")
    }

    private func widgetName(_ account: AccountSnapshot) -> String {
        // Shorten only the verified profile name; preserve official email and slot fallbacks.
        account.fullName?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? account.displayName
    }

    private func compactResourceText(_ value: AccountResourceValue) -> String {
        let text = isSmall ? value.shortText : value.compactText
        // Keep scientific values readable in a column: 1.0E+030 becomes 1e30.
        let parts = text.split(separator: "E")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
        let mantissa = parts[0].hasSuffix(".0") ? String(parts[0].dropLast(2)) : String(parts[0])
        return "\(mantissa)e\(exponent)"
    }

    private func compactResetStatus(_ state: QuotaUsageState) -> String {
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

    private func compactStatus(_ state: QuotaUsageState) -> String {
        switch state {
        case .disconnected: return "Connect\nin app"
        case .needsSignIn: return "Sign in\nagain"
        case .waiting: return "Waiting\nfor usage"
        case .stale: return "Out of\ndate"
        case .unavailable: return "Update\nunavailable"
        case .notReported: return "Not\nreported"
        case .resetElapsed: return "Refresh\nto check"
        case .available: return "—"
        }
    }

    private func accent(_ index: Int) -> Color {
        renderingMode == .accented ? .primary : CodexUsageViewerPalette.accent(for: index)
    }

    private func accountURL(_ account: AccountSnapshot) -> URL {
        URL(string: "codexusageviewer://account/\(account.id)")!
    }
}
