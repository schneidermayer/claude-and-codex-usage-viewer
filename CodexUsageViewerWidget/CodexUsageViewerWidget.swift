import SwiftUI
import WidgetKit

struct CodexUsageViewerUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct CodexUsageViewerUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexUsageViewerUsageEntry {
        CodexUsageViewerUsageEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexUsageViewerUsageEntry) -> Void) {
        completion(CodexUsageViewerUsageEntry(date: .now, snapshot: SharedSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexUsageViewerUsageEntry>) -> Void) {
        let now = Date.now
        let snapshot = SharedSnapshotStore.load()
        let nextReload = now.addingTimeInterval(15 * 60)
        let entries = WeeklyWidgetTimeline.dates(snapshot: snapshot, now: now, reloadAt: nextReload)
            .map { CodexUsageViewerUsageEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(nextReload)))
    }
}

@main
struct CodexUsageViewerWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexUsageViewerSmallWidget()
        CodexUsageViewerUsageWidget()
        CodexUsageViewerDashboardWidget()
    }
}

enum CodexUsageViewerWidgetSize {
    case small, large, dashboard

    var name: String {
        switch self {
        case .small: return "Small"
        case .large: return "Large"
        case .dashboard: return "Dashboard"
        }
    }
    var kind: String {
        switch self {
        case .small: return CodexUsageViewerConstants.smallWidgetKind
        case .large: return CodexUsageViewerConstants.widgetKind
        case .dashboard: return CodexUsageViewerConstants.dashboardWidgetKind
        }
    }
    // Large uses WidgetKit's wide systemMedium family.
    var family: WidgetFamily {
        switch self {
        case .small: return .systemSmall
        case .large: return .systemMedium
        case .dashboard: return .systemLarge
        }
    }
}

struct CodexUsageViewerUsageWidget: Widget {
    var body: some WidgetConfiguration { usageConfiguration(size: .large) }
}

struct CodexUsageViewerSmallWidget: Widget {
    var body: some WidgetConfiguration { usageConfiguration(size: .small) }
}

struct CodexUsageViewerDashboardWidget: Widget {
    var body: some WidgetConfiguration { usageConfiguration(size: .dashboard) }
}

@MainActor
private func usageConfiguration(size: CodexUsageViewerWidgetSize) -> some WidgetConfiguration {
    StaticConfiguration(kind: size.kind, provider: CodexUsageViewerUsageProvider()) { entry in
        Group {
            if size == .dashboard {
                CodexUsageViewerDashboardWidgetContent(snapshot: entry.snapshot, referenceDate: entry.date)
            } else {
                CodexUsageViewerWidgetContent(snapshot: entry.snapshot, family: nil, referenceDate: entry.date)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "codexusageviewer://dashboard"))
    }
    .configurationDisplayName(size.name)
    .description(size == .dashboard
                 ? "Detailed account cards with five-hour and weekly usage, reset countdowns, and Codex resources."
                 : "Five-hour and weekly usage with separate reset countdowns for one to three Claude or Codex accounts, plus Codex credits and earned resets.")
    .supportedFamilies([size.family])
    .contentMarginsDisabled()
}

#Preview("Small", as: .systemSmall) {
    CodexUsageViewerSmallWidget()
} timeline: {
    CodexUsageViewerUsageEntry(date: .now, snapshot: .preview)
}

#Preview("Large", as: .systemMedium) {
    CodexUsageViewerUsageWidget()
} timeline: {
    CodexUsageViewerUsageEntry(date: .now, snapshot: .preview)
    CodexUsageViewerUsageEntry(date: .now, snapshot: .empty)
}

#Preview("Dashboard", as: .systemLarge) {
    CodexUsageViewerDashboardWidget()
} timeline: {
    CodexUsageViewerUsageEntry(date: .now, snapshot: .preview)
    CodexUsageViewerUsageEntry(date: .now, snapshot: .empty)
}
