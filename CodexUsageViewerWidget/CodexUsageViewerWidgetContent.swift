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
    private var accounts: [AccountSnapshot] { Array(snapshot.accounts.prefix(3)) }
    private var narrowColumns: Bool { isSmall && accounts.count == 3 }
    private var nameHeight: CGFloat { narrowColumns ? 14 : 16 }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = isSmall ? 4 : 8
            let count = max(1, accounts.count)
            let columnWidth = max(0, (geometry.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
            HStack(spacing: spacing) {
                ForEach(accounts) { account in
                    Group {
                        if isSmall {
                            accountColumn(account, height: geometry.size.height)
                        } else {
                            Link(destination: accountURL(account)) {
                                accountColumn(account, height: geometry.size.height)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: columnWidth, height: geometry.size.height)
                }
            }
        }
        .padding(.horizontal, isSmall ? 10 : 12)
        .padding(.top, 10)
        .padding(.bottom, isSmall ? 8 : 10)
        .fontDesign(.rounded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude and Codex usage remaining and time until reset")
    }

    private func accountColumn(_ account: AccountSnapshot, height: CGFloat) -> some View {
        let color = accent(CodexUsageViewerPalette.index(for: account.id))
        let resourcesHeight: CGFloat = isSmall ? 14 : 17
        let usageHeight = max(0, height - nameHeight - 2 - 16 - 4 - resourcesHeight - 3)
        let hasBoth = account.fiveHourWindow != nil && account.weeklyWindow != nil
        return VStack(spacing: 0) {
            Text(widgetName(account))
                .font(.system(size: narrowColumns ? 10.5 : 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: nameHeight)
                .accessibilityLabel(account.displayName)
                .help(account.displayName)

            HStack(spacing: narrowColumns ? 1 : 3) {
                subscription(account, color: color)
                if snapshot.isLocalAccount(account, at: referenceDate) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: narrowColumns ? 7 : 9, weight: .semibold))
                        .foregroundStyle(color)
                        .widgetAccentable()
                        .accessibilityLabel("Logged In")
                        .help("Currently signed in to local \(account.provider.displayName)")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 16)
            .padding(.top, 2)

            VStack(spacing: 4) {
                if hasBoth {
                    usagePanel(account, window: account.fiveHourWindow, color: color, compact: true)
                        .frame(height: max(0, (usageHeight - 4) / 2))
                    usagePanel(account, window: account.weeklyWindow, color: color, compact: true)
                        .frame(height: max(0, (usageHeight - 4) / 2))
                } else {
                    usagePanel(account, window: account.weeklyWindow ?? account.fiveHourWindow,
                               color: color, compact: false)
                }
            }
            .frame(height: usageHeight)
            .padding(.top, 4)

            Group {
                if account.provider != .codex {
                    Color.clear.accessibilityHidden(true)
                } else if isSmall {
                    smallResources(account)
                } else {
                    HStack(spacing: 3) {
                        credits(account)
                        Spacer(minLength: 0)
                        availableResets(account)
                    }
                }
            }
            .frame(height: resourcesHeight)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func subscription(_ account: AccountSnapshot, color: Color) -> some View {
        HStack(spacing: 3) {
            CodexUsageViewerProviderMark(provider: account.provider)
                .fill(Color.primary)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(account.subscriptionDisplayName ?? "—")
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, narrowColumns ? 3 : 4)
        .padding(.vertical, 2)
        .background(color.opacity(0.13), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(account.provider.displayName), subscription plan: \(account.subscriptionDisplayName ?? "Unknown plan")")
        .help("\(account.provider.displayName), subscription plan: \(account.subscriptionDisplayName ?? "Unknown plan")")
    }

    @ViewBuilder
    private func usagePanel(_ account: AccountSnapshot, window: QuotaWindow?, color: Color,
                            compact: Bool) -> some View {
        if isSmall {
            smallUsagePanel(account, window: window, color: color, compact: compact)
        } else {
            horizontalUsagePanel(account, window: window, color: color, compact: compact)
        }
    }

    private func smallUsagePanel(_ account: AccountSnapshot, window: QuotaWindow?, color: Color,
                                 compact: Bool) -> some View {
        let state = account.usage(for: window, at: referenceDate)
        let reset = state.window.flatMap { QuotaResetProgress(window: $0, at: referenceDate) }
        let session = window?.windowDurationMins == 300
        let label = session ? "5h" : "7d"
        let fullLabel = window?.label ?? "Usage"
        let showLabel = compact || session
        let size: CGFloat = compact ? (narrowColumns ? 14 : 20) : (narrowColumns ? 24 : 30)
        let description = state.window.map { "\(fullLabel): \($0.remainingPercent) percent remaining" }
            ?? "\(fullLabel) usage unknown. \(state.status ?? "")"
        let resetDescription = reset.map { "Reset in \($0.countdown)" } ?? (state.status ?? "Reset time not reported")
        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if showLabel {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                percentage(state, color: color, size: size, compact: compact)
                    .frame(maxWidth: .infinity, alignment: showLabel ? .trailing : .center)
            }
            .frame(height: compact ? size + 4 : size + 5)
            if !compact { Spacer(minLength: 0) }
            CodexUsageViewerResetTrack(fractionRemaining: reset?.fractionRemaining, accent: color,
                                      segments: session ? 5 : 7, height: 3,
                                      spacing: 1, widgetAccentable: true)
            Text(reset?.countdown ?? compactResetStatus(state))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(height: 11)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { smallUsageFill(remaining: state.window?.remainingPercent, color: color) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(description). \(resetDescription)")
        .help("\(description). \(resetDescription)")
    }

    private func horizontalUsagePanel(_ account: AccountSnapshot, window: QuotaWindow?, color: Color,
                                      compact: Bool) -> some View {
        let state = account.usage(for: window, at: referenceDate)
        let reset = state.window.flatMap { QuotaResetProgress(window: $0, at: referenceDate) }
        let session = window?.windowDurationMins == 300
        let fullLabel = window?.label ?? "Usage"
        let shortLabels = isSmall && accounts.count > 1
        let label = shortLabels && window != nil ? (session ? "5h" : "7d") : fullLabel
        let size: CGFloat = compact ? (narrowColumns ? 14 : 20) : (shortLabels ? 22 : 30)
        let description = state.window.map { "\(fullLabel): \($0.remainingPercent) percent remaining" }
            ?? "\(fullLabel) usage unknown. \(state.status ?? "")"
        let resetDescription = reset.map { "Reset in \($0.countdown)" } ?? (state.status ?? "Reset time not reported")
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: shortLabels ? 8 : 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if !compact && !shortLabels {
                        Text(state.window == nil ? "unknown" : "remaining")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                percentage(state, color: color, size: size, compact: compact)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: compact ? size + 2 : size + 5)
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    if !shortLabels && reset != nil {
                        Text("Resets in")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Text(reset?.countdown ?? compactResetStatus(state))
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: shortLabels ? 9 : 8))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(height: 11)
                CodexUsageViewerResetTrack(fractionRemaining: reset?.fractionRemaining, accent: color,
                                          segments: session ? 5 : 7, height: 3,
                                          spacing: isSmall ? 1 : 2, widgetAccentable: true)
            }
        }
        .padding(.horizontal, isSmall ? 3 : 6)
        .padding(.vertical, 3)
        .padding(.top, compact ? 0 : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { usageFill(remaining: state.window?.remainingPercent, color: color) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(description). \(resetDescription)")
        .help("\(description). \(resetDescription)")
    }

    private func percentage(_ state: QuotaUsageState, color: Color, size: CGFloat,
                            compact: Bool) -> some View {
        let value = state.window.map { String($0.remainingPercent) } ?? "—"
        let suffix = state.window == nil ? "" : "%"
        let suffixSize: CGFloat = compact ? (isSmall ? 9 : 11) : (isSmall ? 10 : 13)
        return Text("\(Text(value).font(.system(size: size, weight: .semibold)))\(Text(suffix).font(.system(size: suffixSize, weight: .medium)))")
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(state.window == nil ? Color.secondary : color)
            .widgetAccentable()
    }

    private func usageFill(remaining: Int?, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                color.opacity(colorScheme == .dark ? 0.055 : 0.04)
                if let remaining, remaining > 0 {
                    color.opacity(colorScheme == .dark ? 0.14 : 0.10)
                        .frame(width: geometry.size.width * CGFloat(remaining) / 100)
                        .overlay(alignment: .trailing) {
                            if remaining < 100 {
                                color.opacity(colorScheme == .dark ? 0.24 : 0.18)
                                    .frame(width: 0.5)
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .widgetAccentable()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func smallUsageFill(remaining: Int?, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                color.opacity(colorScheme == .dark ? 0.045 : 0.03)
                if let remaining, remaining > 0 {
                    color.opacity(colorScheme == .dark ? 0.14 : 0.10)
                        .frame(height: geometry.size.height * CGFloat(remaining) / 100)
                        .overlay(alignment: .top) {
                            if remaining < 100 {
                                color.opacity(colorScheme == .dark ? 0.24 : 0.18)
                                    .frame(height: 0.5)
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .widgetAccentable()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func smallResources(_ account: AccountSnapshot) -> some View {
        let credits = account.creditsValue(at: referenceDate)
        let resets = account.resetsValue(at: referenceDate)
        let description = "Available credits: \(credits.accessibilityText). Available usage resets: \(resets.accessibilityText)"
        let row = Text("\(Image(systemName: "c.circle")) \(compactResourceText(credits))  \(Image(systemName: "arrow.counterclockwise")) \(compactResourceText(resets))")
        // Size symbols and digits together; Text's minimumScaleFactor does not
        // reliably shrink interpolated symbols in a narrow widget column.
        return ViewThatFits(in: .horizontal) {
            row.font(.system(size: 9, weight: .medium)).fixedSize()
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

    private func accent(_ index: Int) -> Color {
        renderingMode == .accented ? .primary : CodexUsageViewerPalette.accent(for: index)
    }

    private func accountURL(_ account: AccountSnapshot) -> URL {
        URL(string: "codexusageviewer://account/\(account.id)")!
    }
}
