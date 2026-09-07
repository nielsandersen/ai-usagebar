import Foundation
import CloudKit

enum WidgetSyncError: Error, LocalizedError {
    case signing, simulator, signedOut, unavailable, empty
    var errorDescription: String? {
        switch self {
        case .signing: return "iCloud sync needs an Apple Developer team and a signed build. See the widget setup guide."
        case .simulator: return "This simulator build uses local data. Verify iCloud sync on your signed devices."
        case .signedOut: return "Sign in to iCloud in Settings, then try again."
        case .unavailable: return "Couldn't reach iCloud. Your saved usage is still available. Try again shortly."
        case .empty: return "No Mac update yet. Enable Sync Widgets with iCloud in the Mac app."
        }
    }
}
actor CloudSnapshotStore {
    static let shared = CloudSnapshotStore()
    private let recordID = CKRecord.ID(recordName: "current-usage-v1")
    private func database() async throws -> CKDatabase {
        #if targetEnvironment(simulator)
        throw WidgetSyncError.simulator
        #else
        guard let team = Bundle.main.object(forInfoDictionaryKey: "UsageDeveloperTeam") as? String,
              !team.isEmpty, !team.contains("$("),
              let identifier = Bundle.main.object(forInfoDictionaryKey: "UsageCloudContainer") as? String,
              !identifier.isEmpty else { throw WidgetSyncError.signing }
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { throw WidgetSyncError.signedOut }
        return container.privateCloudDatabase
        #endif
    }
    func fetch() async throws -> UsageSnapshot {
        do {
            let db = try await database()
            let record = try await db.record(for: recordID)
            guard let data = record["payload"] as? Data else { throw SnapshotError.invalid }
            return try UsageSnapshot.decode(data)
        } catch let error as WidgetSyncError { throw error }
        catch let error as CKError where error.code == .unknownItem { throw WidgetSyncError.empty }
        catch { throw WidgetSyncError.unavailable }
    }
    func publish(_ snapshot: UsageSnapshot) async throws {
        do {
            let data = try snapshot.encoded()
            _ = try UsageSnapshot.decode(data)
            let db = try await database()
            let record: CKRecord
            do { record = try await db.record(for: recordID) }
            catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "UsageSnapshot", recordID: recordID)
            }
            if let previous = record["payload"] as? Data,
               let old = try? UsageSnapshot.decode(previous), !snapshot.supersedes(old) { return }
            record["payload"] = data as CKRecordValue
            let results = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            guard let saved = results.saveResults[recordID] else { throw WidgetSyncError.unavailable }
            _ = try saved.get()
        } catch let error as WidgetSyncError { throw error }
        catch { throw WidgetSyncError.unavailable }
    }
}
