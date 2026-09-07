import SwiftUI
import WidgetKit

@MainActor
final class CompanionModel: ObservableObject {
    @Published var snapshot = WidgetStore().load()
    @Published var message: String?
    @Published var syncing = false
    @Published var enabled = WidgetStore().syncEnabled
    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        WidgetStore().setSyncEnabled(true); enabled = true
        do {
            let fresh = try await CloudSnapshotStore.shared.fetch()
            try WidgetStore().save(fresh)
            snapshot = WidgetStore().load()
            WidgetStore().reloadWidgets()
            message = nil
        } catch { message = (error as? LocalizedError)?.errorDescription ?? "Sync unavailable. Try again shortly." }
    }
    func stopSync() {
        enabled = false
        WidgetStore().setSyncEnabled(false)
        WidgetStore().reloadWidgets()
    }
}
@main
struct UsageCompanion: App {
    var body: some Scene { WindowGroup { CompanionView() } }
}
struct CompanionView: View {
    @StateObject private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let snapshot = model.snapshot {
                        Label(snapshot.summary(at: Date()), systemImage: snapshot.isHealthy(at: Date()) ? "checkmark.circle" : "clock")
                        LabeledContent("Last Mac update") { Text(snapshot.generatedAt, style: .relative) }
                        ForEach(snapshot.rankedProviders) { provider in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.name)
                                    Text(provider.displayHealth(at: Date()).phrase).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(provider.highestMetric.map { "\($0.percent)%" } ?? provider.balance ?? "—").monospacedDigit()
                            }
                        }
                    } else {
                        ContentUnavailableView("Connect your Mac", systemImage: "laptopcomputer.and.iphone", description: Text("Enable Sync Widgets with iCloud in AI Usage Bar on your Mac. Use the same iCloud account on both devices."))
                    }
                    Button { Task { await model.sync() } } label: {
                        HStack {
                            Text(model.syncing ? "Syncing…" : "Sync from Mac")
                            Spacer()
                            if model.syncing { ProgressView() }
                            else { Image(systemName: "arrow.triangle.2.circlepath") }
                        }
                    }.disabled(model.syncing)
                    if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                } footer: { Text("Only usage summaries sync through your private iCloud database. Provider passwords and API keys stay on your Mac.") }
                Section("Your widgets") {
                    NavigationLink("Preview widget sizes") { WidgetGallery() }
                    Text("Touch and hold your Home Screen, choose Edit → Add Widget, then search for AI Usage Bar. For the compact Lock Screen view, customize your Lock Screen and add AI Usage Bar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.enabled {
                    Section {
                        Button("Pause iCloud downloads") { model.stopSync() }.disabled(model.syncing)
                    } footer: { Text("Saved usage stays on this phone. Pause publishing separately on your Mac.") }
                }
            }
            .navigationTitle("AI Usage")
            .refreshable { if model.enabled { await model.sync() } }
            .task { if model.enabled { await model.sync() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active && model.enabled { Task { await model.sync() } }
            }
        }
    }
}
struct WidgetGallery: View {
    private var example: UsageSnapshot {
        let now = Date()
        return UsageSnapshot(generatedAt: now, providers: [
            ProviderUsage(id: "claude", name: "Claude", health: .healthy, checkedAt: now, usageAt: now, metrics: [UsageMetric(label: "Session", percent: 64), UsageMetric(label: "Weekly", percent: 38)], balance: nil),
            ProviderUsage(id: "codex", name: "Codex", health: .healthy, checkedAt: now, usageAt: now, metrics: [UsageMetric(label: "Session", percent: 27)], balance: nil),
            ProviderUsage(id: "openrouter", name: "OpenRouter", health: .healthy, checkedAt: now, usageAt: now, metrics: [], balance: "$12.40 credit")
        ])
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Design previews · example data").font(.caption).foregroundStyle(.secondary)
                preview("Compact", family: .systemSmall, width: 166, height: 166)
                preview("Donut", family: .systemMedium, width: 338, height: 158)
                preview("Overview", family: .systemLarge, width: 338, height: 354)
                preview("Lock Screen", family: .accessoryRectangular, width: 170, height: 70)
            }.padding()
        }.navigationTitle("Widget sizes").navigationBarTitleDisplayMode(.inline)
    }
    private func preview(_ title: String, family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            UsageWidgetView(entry: UsageEntry(date: Date(), snapshot: example), familyOverride: family)
                .padding(16).frame(width: width, height: height)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
