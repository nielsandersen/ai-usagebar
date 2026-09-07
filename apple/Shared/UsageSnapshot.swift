import Foundation

enum UsageHealth: String, Codable, Equatable {
    case healthy, checking, signInRequired, setupRequired, keychainLocked, rateLimited, unavailable, stale
    var phrase: String {
        switch self {
        case .healthy: return "connected"
        case .checking: return "is being checked"
        case .signInRequired: return "needs sign-in"
        case .setupRequired: return "needs setup"
        case .keychainLocked: return "needs Keychain access"
        case .rateLimited: return "is rate limited"
        case .unavailable: return "isn't responding"
        case .stale: return "needs a fresh check"
        }
    }
}
struct UsageMetric: Codable, Equatable { var label: String; var percent: Int }
struct ProviderUsage: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var health: UsageHealth
    var checkedAt: Date?
    var usageAt: Date?
    var metrics: [UsageMetric]
    var balance: String?
    var highestMetric: UsageMetric? { metrics.max { $0.percent < $1.percent } }
    func displayHealth(at date: Date) -> UsageHealth {
        guard health == .healthy else { return health }
        guard let checkedAt, let usageAt,
              date.timeIntervalSince(checkedAt) >= -60,
              date.timeIntervalSince(checkedAt) < UsageSnapshot.maxAge,
              date.timeIntervalSince(usageAt) >= -60,
              date.timeIntervalSince(usageAt) < UsageSnapshot.maxAge else { return .stale }
        return .healthy
    }
}
struct UsageSnapshot: Codable, Equatable {
    static let maxAge: TimeInterval = 30 * 60
    static let maximumBytes = 256 * 1024
    var schemaVersion = 1
    var generatedAt: Date
    var providers: [ProviderUsage]
    var rankedProviders: [ProviderUsage] {
        providers.sorted {
            let a = $0.highestMetric?.percent ?? -1, b = $1.highestMetric?.percent ?? -1
            return a == b ? $0.id < $1.id : a > b
        }
    }
    func summary(at date: Date) -> String {
        if providers.isEmpty { return "No services configured" }
        guard date.timeIntervalSince(generatedAt) >= -60, date.timeIntervalSince(generatedAt) < Self.maxAge else { return "Waiting for a fresh Mac update" }
        let issues = providers.filter { $0.displayHealth(at: date) != .healthy }
        if issues.isEmpty { return "All services connected" }
        if issues.count == 1, let p = issues.first { return "\(p.name) \(p.displayHealth(at: date).phrase)" }
        return "\(issues.count) connections need attention"
    }
    func isHealthy(at date: Date) -> Bool {
        !providers.isEmpty && date.timeIntervalSince(generatedAt) >= -60 && date.timeIntervalSince(generatedAt) < Self.maxAge && providers.allSatisfy { $0.displayHealth(at: date) == .healthy }
    }
    /// Ignore an implausibly future-dated cache after a source clock correction.
    func supersedes(_ existing: UsageSnapshot, at now: Date = Date()) -> Bool {
        existing.generatedAt > now.addingTimeInterval(60) || generatedAt >= existing.generatedAt
    }
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SnapshotError.invalid }
        let s = try JSONDecoder().decode(Self.self, from: data)
        guard s.schemaVersion == 1, s.providers.count <= 64,
              Set(s.providers.map(\.id)).count == s.providers.count,
              s.providers.allSatisfy({ p in
                  !p.id.isEmpty && p.id.count <= 160 && !p.name.isEmpty && p.name.count <= 80 &&
                  p.metrics.count <= 8 && (p.balance?.count ?? 0) <= 80 &&
                  p.metrics.allSatisfy { !$0.label.isEmpty && $0.label.count <= 80 && (0...100).contains($0.percent) }
              }) else { throw SnapshotError.invalid }
        return s
    }
}
enum SnapshotError: Error { case invalid, unavailable }
