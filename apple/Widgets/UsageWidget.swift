import SwiftUI
import WidgetKit

struct UsageTimeline: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: WidgetStore().load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let store = WidgetStore()
            #if os(iOS)
            if store.syncEnabled, let snapshot = try? await CloudSnapshotStore.shared.fetch() { try? store.save(snapshot) }
            #endif
            let snapshot = store.load()
            let now = Date()
            var dates = [now]
            if let snapshot {
                let deadlines = [snapshot.generatedAt] + snapshot.providers.flatMap { [$0.checkedAt, $0.usageAt].compactMap { $0 } }
                dates += deadlines.map { $0.addingTimeInterval(UsageSnapshot.maxAge + 1) }.filter { $0 > now && $0 < now.addingTimeInterval(3600) }
            }
            let entries = Set(dates).sorted().map { UsageEntry(date: $0, snapshot: snapshot) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(1800))))
        }
    }
}
@main
struct AIUsageWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kind, provider: UsageTimeline()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "aiusagebar://overview"))
        }
        .configurationDisplayName("AI Usage Bar")
        .description("Compact usage or detailed donuts, with connection health and the time of the last Mac update.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}
