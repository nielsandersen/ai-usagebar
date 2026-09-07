# AI Usage Bar widgets

Native WidgetKit development build for macOS 14+ and iOS 17+. The existing Mac
monitor is the only provider client. The iPhone receives typed usage summaries
through the same user's private CloudKit database; it never receives API keys,
OAuth tokens, Keychain contents, or raw provider responses.

## Sizes

- Small Home Screen/Desktop widget: compact provider/percentage rows.
- Medium: the most constrained provider's donut, with its quota windows.
- Large: up to three provider donuts, with balance and health details.
- iPhone Lock Screen: rectangular and inline compact status.

The companion's **Preview widget sizes** gallery uses explicitly labelled example
data, never saved as real usage. Widgets themselves never substitute demo data.
Widgets show last Mac update time; data/checks older than 30 minutes become stale.
The OS controls actual refresh timing. Cached values do not imply a fresh login.

## Usage colors

Royal blue is the normal accent, with a lighter blue in dark appearance.
At 75–89% usage, numbers and rings become amber; at 90% and above they turn red,
matching the menu app's warning thresholds. Text and warning symbols distinguish
“High usage”, “Near limit”, and “Limit reached” (100%), including in system-tinted
widgets. These quota warnings do not imply a failed provider connection.
The preview gallery includes normal, high, near-limit and at-limit examples.

## Build and test now

Requires Xcode 26.2 (tested), Command Line Tools, and XcodeGen 2.45.4 (tested).
From the repository root:

```sh
./apple/verify.sh
```

This generates `apple/AIUsageBar.xcodeproj`, runs shared tests, builds both hosts
and embedded extensions without signing, runs existing menu tests, and checks the
widget adapter's handling of balances and spending limits. Build output lives
under ignored `apple/build` and `apple/build-mac` directories. Open the generated
project and select **UsagePhone** to run the companion on a simulator.

Unsigned builds do not establish production iCloud capability. Simulator sync
intentionally returns an explanatory message. Preview gallery rendering is not
an end-to-end CloudKit test.

## Finish installation after developer enrollment

1. Enroll at https://developer.apple.com/programs/enroll/ using your Apple account.
   Enrollment/payment/terms are your actions; this repository does not perform them.
2. Add that account in Xcode → Settings → Accounts. Note your Developer Team ID.
3. Copy `apple/Configuration/Local.xcconfig.example` to
   `apple/Configuration/Local.xcconfig`, and replace `YOUR_TEAM_ID`. This file is
   ignored by Git. Keep the bundle/group/container identifiers consistent across
   all four targets; change the prefix if the default identifiers are unavailable.
4. In Apple Certificates, Identifiers & Profiles, register the four app IDs:
   `com.nielsandersen.aiusagebar.mac`, `.mac.widget`, `.phone`, `.phone.widget`.
   Register the App Group `group.com.nielsandersen.aiusagebar` and CloudKit
   container `iCloud.com.nielsandersen.aiusagebar`. Associate the group and
   CloudKit container with the relevant targets. Enable the App Groups and
   iCloud/CloudKit capabilities in Xcode and let automatic signing create the
   development profiles. Confirm the generated entitlements match your account.
5. Regenerate with `xcodegen generate --spec apple/project.yml`. Build **UsageMac**
   with your real team. Do not run the unsigned Mac product as a deployment test.
   The Mac host is intentionally not sandboxed, because it retains the existing
   CLI process/config/Keychain integration. Its widget extension is sandboxed.
6. Quit the installed menu-bar copy before starting the signed Mac app, avoiding
   duplicate polling. Keep its old installed version for rollback. The signed
   app reads the existing `ai-usagebar-menubar` preference domain and backend
   `binaryPath`; the personal CLI installation is still required. Verify the
   backend path under Settings if moving between machines. This project does not
   replace the versioned installer or silently modify its LaunchAgent.
7. Enable **Actions → Sync Widgets with iCloud** on the signed Mac app. Reopen
   Actions to read the sync result. Enabling sends provider/account display names,
   usage percentages, balance text, health, and source timestamps. Turning it off
   prevents future uploads; it does not erase the previously synced private record.
8. Connect your iPhone, enable Developer Mode if requested by iOS, select it as
   the **UsagePhone** run destination, and build/run with the same team and iCloud
   account. Tap **Sync from Mac**. Add widgets from the Home Screen widget gallery;
   add compact widgets while customizing the Lock Screen. On Mac, use Edit Widgets
   after launching the signed host to register the extension.
9. For distribution/TestFlight, deploy the `UsageSnapshot` record schema (field
   `payload`: Bytes) from CloudKit development to production in CloudKit Console,
   and verify a distribution-signed build against production. Review App Store
   icon/privacy/submission metadata separately before uploading. No distribution
   build or production schema has been published by this change.

## Required physical-device acceptance checks

- Real Mac usage → private CloudKit → iPhone app → iPhone Home/Lock Screen widget.
- Mac desktop widget reads the App Group snapshot without cloud access.
- Sign out / network loss retains cached data and displays actionable sync failure.
- Stop the Mac; after 30 minutes widgets show stale rather than all-clear.
- Reject a provider login; its connection state reaches the phone without tokens.
- Correct a future Mac clock; subsequent real snapshots replace the invalid cache.
- Pause cloud sync on both devices; no new cloud requests start. An in-flight request
  may finish; existing snapshots remain available.
- Verify small/medium/large widgets in light, dark, tinted, and large text modes.

## Architecture

`macos/ai-usagebar-menubar.swift` includes its publisher only under `WIDGET_HOST`.
Standalone menu builds remain unchanged. `Shared/UsageSnapshot.swift` is the
allowlisted, validated schema; `SnapshotFile.swift` handles atomic local writes.
`WidgetStore.swift` uses the App Group; `CloudSnapshotStore.swift` uses only
`privateCloudDatabase` with record `current-usage-v1`. It validates the payload,
checks individual save results, and rejects older data except when replacing an
implausibly future-dated cache. `WidgetPublisher.swift` serializes uploads and
limits attempts to once per two minutes; WidgetCenter reload hints are limited
to once per minute during monitoring. Errors contain fixed recovery copy.

The phone and widget download only after the companion's sync action opts in.
Timeline entries explicitly mark data stale at its deadline even if the next
network refresh is delayed. A widget timeline requests another check after
30 minutes; this is not a guarantee from WidgetKit.
