import Foundation
struct SnapshotFile {
    let url: URL
    func load() throws -> UsageSnapshot { try UsageSnapshot.decode(Data(contentsOf: url)) }
    func save(_ snapshot: UsageSnapshot) throws {
        let data = try snapshot.encoded()
        _ = try UsageSnapshot.decode(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
