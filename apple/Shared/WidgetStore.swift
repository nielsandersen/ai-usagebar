import Foundation
import WidgetKit

struct WidgetStore {
    static let kind = "AIUsageOverview"
    var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "UsageAppGroup") as? String }
    var defaults: UserDefaults? { groupID.flatMap { UserDefaults(suiteName: $0) } }
    var file: SnapshotFile? {
        guard let groupID, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return SnapshotFile(url: url.appendingPathComponent("usage-snapshot.json"))
    }
    var syncEnabled: Bool { defaults?.bool(forKey: "cloudSyncEnabled") ?? false }
    func setSyncEnabled(_ enabled: Bool) { defaults?.set(enabled, forKey: "cloudSyncEnabled") }
    func load() -> UsageSnapshot? { try? file?.load() }
    func save(_ snapshot: UsageSnapshot) throws {
        guard let file else { throw SnapshotError.unavailable }
        // A delayed network response must not replace a newer snapshot.
        if let old = try? file.load(), !snapshot.supersedes(old) { return }
        try file.save(snapshot)
    }
    func reloadWidgets() { WidgetCenter.shared.reloadTimelines(ofKind: Self.kind) }
}
