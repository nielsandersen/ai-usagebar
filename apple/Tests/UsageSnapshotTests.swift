import XCTest
@testable import UsageWidgetCore
final class UsageSnapshotTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func sample(_ percent: Int = 42) -> UsageSnapshot {
        UsageSnapshot(generatedAt: now, providers: [ProviderUsage(id: "claude", name: "Claude", health: .healthy, checkedAt: now, usageAt: now, metrics: [UsageMetric(label: "Session", percent: percent)], balance: nil)])
    }
    func testRoundTripAndFullQuotaIsConnected() throws {
        let s = sample(100)
        XCTAssertEqual(try UsageSnapshot.decode(s.encoded()), s)
        XCTAssertEqual(s.summary(at: now), "All services connected")
    }
    func testStaleAndClockSkewNeverGreen() {
        XCTAssertNotEqual(sample().summary(at: now.addingTimeInterval(1900)), "All services connected")
        XCTAssertNotEqual(sample().summary(at: now.addingTimeInterval(-600)), "All services connected")
    }
    func testMissingChecksNotHealthy() {
        var s = sample(); s.providers[0].checkedAt = nil
        XCTAssertNotEqual(s.summary(at: now), "All services connected")
    }
    func testUsageKeepsItsOwnAge() {
        var s = sample(); s.providers[0].usageAt = now.addingTimeInterval(-3600)
        XCTAssertEqual(s.providers[0].displayHealth(at: now), .stale)
    }
    func testBadSchemaBoundsAndDuplicateIDsRejected() throws {
        var s = sample(); s.schemaVersion = 99
        XCTAssertThrowsError(try UsageSnapshot.decode(s.encoded()))
        s = sample(101); XCTAssertThrowsError(try UsageSnapshot.decode(s.encoded()))
        s = sample(); s.providers.append(s.providers[0]); XCTAssertThrowsError(try UsageSnapshot.decode(s.encoded()))
        XCTAssertThrowsError(try UsageSnapshot.decode(Data("oops".utf8)))
    }
    func testEmptyAndFailedProviderSummary() {
        XCTAssertEqual(UsageSnapshot(generatedAt: now, providers: []).summary(at: now), "No services configured")
        var s = sample(); s.providers[0].health = .signInRequired
        XCTAssertEqual(s.summary(at: now), "Claude needs sign-in")
    }
    func testMostConstrainedProviderFirst() {
        var s = sample(12); var other = s.providers[0]; other.id = "codex"; other.name = "Codex"; other.metrics[0].percent = 86
        s.providers.append(other)
        XCTAssertEqual(s.rankedProviders.first?.name, "Codex")
    }
    func testClockCorrectionCanReplaceFutureCache() {
        var future = sample(); future.generatedAt = now.addingTimeInterval(86400)
        XCTAssertTrue(sample().supersedes(future, at: now))
        var recent = sample(); recent.generatedAt = now.addingTimeInterval(10)
        XCTAssertFalse(sample().supersedes(recent, at: now))
    }
    func testAtomicFileAndCorruptCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SnapshotFile(url: root.appendingPathComponent("snapshot.json"))
        try file.save(sample()); try file.save(sample(80))
        XCTAssertEqual(try file.load(), sample(80))
        try Data("bad".utf8).write(to: file.url)
        XCTAssertThrowsError(try file.load())
    }
    func testPayloadContainsOnlySummaryFields() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sample().encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "generatedAt", "providers"])
        let p = try XCTUnwrap((object["providers"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(p.keys), ["id", "name", "health", "checkedAt", "usageAt", "metrics"])
    }
}
