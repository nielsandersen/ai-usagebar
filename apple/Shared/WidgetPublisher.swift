#if os(macOS)
import Foundation

/// Called on the menu app's main queue. One cloud request at a time; failed
/// attempts retry on a later monitoring update, at most once per two minutes.
final class WidgetPublisher {
    private let store = WidgetStore()
    private var latest: UsageSnapshot?
    private var lastAttempt = Date.distantPast
    private var uploading = false
    private var lastReload = Date.distantPast
    private(set) var message = "iCloud sync is off"
    var enabled: Bool { store.syncEnabled }
    func setEnabled(_ enabled: Bool) {
        store.setSyncEnabled(enabled)
        message = enabled ? "Waiting to sync" : "iCloud sync is off"
        if enabled { lastAttempt = .distantPast; uploadIfNeeded() }
        store.reloadWidgets()
    }
    func update(_ snapshot: UsageSnapshot) {
        latest = snapshot
        do { try store.save(snapshot) }
        catch { message = "Widget storage needs a signed App Group build"; return }
        if Date().timeIntervalSince(lastReload) >= 60 {
            store.reloadWidgets()
            lastReload = Date()
        }
        if !snapshot.providers.contains(where: { $0.health == .checking }) { uploadIfNeeded() }
    }
    private func uploadIfNeeded() {
        guard enabled, !uploading, Date().timeIntervalSince(lastAttempt) >= 120, let snapshot = latest else { return }
        uploading = true
        lastAttempt = Date()
        message = "Syncing with iCloud…"
        Task {
            let result: String
            do { try await CloudSnapshotStore.shared.publish(snapshot); result = "Usage synced with iCloud" }
            catch { result = (error as? LocalizedError)?.errorDescription ?? "iCloud sync unavailable" }
            await MainActor.run {
                self.uploading = false
                self.message = self.enabled ? result : "iCloud sync is off"
            }
        }
    }
}
#endif
