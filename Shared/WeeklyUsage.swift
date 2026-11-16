import Foundation

extension AccountSnapshot {
    /// Keep the same shortest-to-longest order in the dashboard and widgets,
    /// regardless of which slot the provider uses.
    var usageWindows: [QuotaWindow] {
        guard let bucket = primaryBucket else { return [] }
        return [bucket.primary, bucket.secondary].compactMap { $0 }
            .sorted { ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max) }
    }

    var fiveHourWindow: QuotaWindow? {
        usageWindows.first { $0.windowDurationMins == 300 }
    }

    /// Weekly quota may occupy either slot; never substitute session usage.
    var weeklyWindow: QuotaWindow? {
        usageWindows.first { $0.windowDurationMins == 10_080 }
    }

    func weeklyUsage(at date: Date = .now) -> QuotaUsageState {
        usage(for: weeklyWindow, at: date)
    }

    func usage(for window: QuotaWindow?, at date: Date = .now) -> QuotaUsageState {
        switch state {
        case .disconnected: return .disconnected
        case .needsSignIn: return .needsSignIn
        case .connected:
            guard issue == nil else { return .unavailable }
            guard updatedAt != nil else { return .waiting }
            guard !isStale(at: date) else { return .stale }
            guard let window else { return .notReported }
            guard window.usedPercent.isFinite, window.usedPercent >= 0 else { return .unavailable }
            guard !window.hasElapsed(at: date) else { return .resetElapsed }
            return .available(window)
        }
    }
}

enum QuotaUsageState: Equatable {
    case available(QuotaWindow)
    case disconnected, needsSignIn, waiting, stale, unavailable, notReported, resetElapsed

    var window: QuotaWindow? {
        if case .available(let window) = self { return window }
        return nil
    }

    var status: String? {
        switch self {
        case .available: return nil
        case .disconnected: return "Connect in app"
        case .needsSignIn: return "Sign in again"
        case .waiting: return "Waiting for usage"
        case .stale: return "Usage out of date"
        case .unavailable: return "Update unavailable"
        case .notReported: return "Usage not reported"
        case .resetElapsed: return "Reset passed · refresh"
        }
    }

    /// Short status for a widget's countdown slot.
    var compactStatus: String {
        switch self {
        case .available, .notReported: return "—"
        case .disconnected: return "Connect"
        case .needsSignIn: return "Sign in"
        case .waiting: return "Waiting"
        case .stale: return "Stale"
        case .unavailable: return "Unavailable"
        case .resetElapsed: return "Refresh"
        }
    }
}

struct WeeklyResetProgress: Equatable {
    static let duration: TimeInterval = 7 * 24 * 60 * 60
    private let progress: QuotaResetProgress

    init?(window: QuotaWindow, at date: Date = .now) {
        guard window.windowDurationMins == 10_080,
              let progress = QuotaResetProgress(window: window, at: date) else { return nil }
        self.progress = progress
    }

    var secondsRemaining: TimeInterval { progress.secondsRemaining }
    var fractionRemaining: Double { progress.fractionRemaining }
    var countdown: String { progress.countdown }
}

struct QuotaResetProgress: Equatable {
    let duration: TimeInterval
    let secondsRemaining: TimeInterval

    init?(window: QuotaWindow, at date: Date = .now) {
        guard let minutes = window.windowDurationMins, minutes > 0,
              let resetDate = window.resetDate else { return nil }
        let remaining = resetDate.timeIntervalSince(date)
        guard remaining.isFinite, remaining > 0 else { return nil }
        duration = Double(minutes) * 60
        secondsRemaining = remaining
    }

    var fractionRemaining: Double { min(1, max(0, secondsRemaining / duration)) }

    var countdown: String {
        if secondsRemaining < 60 { return "<1m" }
        // Round down to avoid overstating time remaining.
        let minutes = Int(min(secondsRemaining / 60, Double(Int.max / 60)))
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

enum WeeklyWidgetTimeline {
    static func dates(snapshot: UsageSnapshot, now: Date, reloadAt: Date) -> [Date] {
        var dates = [now, reloadAt]
        // Update countdowns from cached data; the host controls delivery.
        var tick = now.addingTimeInterval(5 * 60)
        while tick < reloadAt {
            dates.append(tick)
            tick = tick.addingTimeInterval(5 * 60)
        }
        let timestamps = snapshot.accounts.compactMap(\.updatedAt)
            + [snapshot.localCodexCheckedAt, snapshot.localClaudeCheckedAt].compactMap { $0 }
        for timestamp in timestamps {
            let staleAt = timestamp.addingTimeInterval(CodexUsageViewerConstants.staleInterval + 1)
            if staleAt > now && staleAt < reloadAt { dates.append(staleAt) }
        }
        for account in snapshot.accounts {
            let changes = [account.fiveHourWindow, account.weeklyWindow, account.fableWindow].map { $0?.resetDate }
                + [account.resetCredits, account.fableResetCredits].map { $0?.expiryDate }
            dates += changes.compactMap { $0 }.filter { $0 > now && $0 < reloadAt }
        }
        return Set(dates).sorted()
    }
}

/// One icon-and-value item in a widget's bottom resource row.
struct WidgetResource: Hashable {
    let symbol: String
    let text: String
    let label: String
    /// Earned resets align to the trailing edge.
    let trailing: Bool
}

extension AccountSnapshot {
    /// Credits precede provider-specific limits and earned resets.
    func widgetResources(at date: Date, short: Bool) -> [WidgetResource] {
        func item(_ symbol: String, _ value: AccountResourceValue, _ label: String, trailing: Bool) -> WidgetResource {
            WidgetResource(symbol: symbol, text: value.widgetText(short: short), label: "\(label): \(value.accessibilityText)", trailing: trailing)
        }
        let resets = item("arrow.counterclockwise", resetsValue(at: date), "Available usage resets", trailing: true)
        if provider == .codex {
            return [item("c.circle", creditsValue(at: date), "Available credits", trailing: false), resets]
        }
        var items = [item("c.circle", creditsValue(at: date), "Available credits", trailing: false)]
        if let fable = fableWindow {
            let remaining = usage(for: fable, at: date).window?.remainingPercent
            items.append(WidgetResource(symbol: "sparkles", text: remaining.map { "\($0)%" } ?? "—",
                                        label: "Fable limit: \(remaining.map { "\($0) percent remaining" } ?? "unknown")", trailing: false))
        }
        if hasEarnedResets {
            items += [resets, item("sparkle", resetsValue(fable: true, at: date), "Available Fable resets", trailing: true)]
        }
        return items
    }

    /// Narrow Small columns keep balances and limits above the earned resets.
    /// Every column reserves the same rows so quota panels stay aligned.
    func widgetResourceRows(at date: Date, short: Bool, stacked: Bool) -> [[WidgetResource]] {
        let items = widgetResources(at: date, short: short)
        guard stacked else { return [items] }
        return [items.filter { !$0.trailing }, items.filter(\.trailing)]
    }
}

extension AccountResourceValue {
    func widgetText(short: Bool) -> String {
        let text = short ? shortText : compactText
        // Keep scientific values readable in a column: 1.0E+030 becomes 1e30.
        let parts = text.split(separator: "E")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
        let mantissa = parts[0].hasSuffix(".0") ? String(parts[0].dropLast(2)) : String(parts[0])
        return "\(mantissa)e\(exponent)"
    }
}
