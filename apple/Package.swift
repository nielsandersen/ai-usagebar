// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "UsageWidgetCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "UsageWidgetCore", targets: ["UsageWidgetCore"])], targets: [
    .target(name: "UsageWidgetCore", path: "Shared", exclude: ["WidgetStore.swift", "CloudSnapshotStore.swift", "WidgetPublisher.swift", "UsageWidgetView.swift", "UsageEntry.swift"], sources: ["UsageSnapshot.swift", "SnapshotFile.swift"]),
    .testTarget(name: "UsageWidgetCoreTests", dependencies: ["UsageWidgetCore"], path: "Tests")
])
