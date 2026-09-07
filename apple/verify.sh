#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift test --package-path apple
xcodegen generate --spec apple/project.yml
xcodebuild -project apple/AIUsageBar.xcodeproj -scheme UsagePhone -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/AIUsageBar.xcodeproj -scheme UsageMac -configuration Debug -destination 'platform=macOS' -derivedDataPath apple/build-mac CODE_SIGNING_ALLOWED=NO build
./macos/run-tests.sh
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -parse-as-library -D SWIFT_TEST_HARNESS -D WIDGET_HOST \
  macos/ai-usagebar-menubar.swift macos/ai-usagebar-tests.swift \
  apple/Shared/UsageSnapshot.swift apple/Shared/SnapshotFile.swift \
  apple/Shared/WidgetStore.swift apple/Shared/CloudSnapshotStore.swift apple/Shared/WidgetPublisher.swift \
  -o "$WORK/widget-adapter-tests"
"$WORK/widget-adapter-tests"
