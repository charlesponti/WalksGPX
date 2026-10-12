---
title: Development and verification
summary: Provides project generation, build, test, and device-validation workflows.
type: guide
status: active
owner: charlesponti
tags: [development, xcode, testing]
related: [architecture.md, healthkit-sync.md, macos-workflow.md]
updated: 2026-10-11
---

# Development and verification

## Prerequisites

Install Xcode, XcodeGen, and an Apple Developer team for physical-device
signing. XcodeGen configuration uses Swift 6, iOS 17, macOS 14, and Lottie
4.6.1 (`project.yml:1-14`). Bundle identifiers and entitlements are configured
per target in `project.yml:15-60`.

## Generate and open

```sh
xcodegen generate
open 'WalksGPX.xcodeproj'
```

When changing target settings or source/resource membership, edit `project.yml`
and regenerate the project. The generated `.xcodeproj` is checked in to make
the app directly openable, but project.yml is the declarative source.

## Build and tests

```sh
xcodebuild -project WalksGPX.xcodeproj -scheme 'WalksGPX iOS' -destination 'generic/platform=iOS' build
xcodebuild -project WalksGPX.xcodeproj -scheme 'WalksGPX macOS' -destination 'generic/platform=macOS' build
xcodebuild -project WalksGPX.xcodeproj -scheme 'WalksGPX iOS' -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The exact available simulator name varies by installed Xcode; inspect with
`xcrun simctl list devices available` and substitute an installed device. The
test target covers sync-state encoding/compatibility, progress bounds, route
processing, GPX output, Core Data in-memory persistence and CloudKit store
configuration, and manifest operations. In-memory stores deliberately omit
CloudKit options so unit tests do not depend on the signed-in account or
CloudKit schema. Tests do not prove iCloud account access, CloudKit schema
provisioning, historical route upload, or cross-device arrival; those need a
signed iPhone/Mac integration check.

When an iOS test run reports an early unexpected exit, inspect its `.ips`
crash report and the Xcode test operation before blaming the persistence
change. On Xcode 27 / iOS Simulator 26.5, this project once crashed in the
system CoreText `ApplyVariationsToGlyph` path before XCTest connected; a second
run stalled in Xcode's simulator-launch worker without launching the app. Those
are test-host/environment failures, not passing tests or evidence of a
CloudKit failure. Re-run once on another simulator or use a build-only check,
and record the exact unresolved test limitation if the harness remains stuck.

The hosted XCTest app itself can be unsigned in simulator test runs and lack
the app's iCloud-container entitlement. Starting the production CloudKit-backed
store from that host can crash inside `PFCloudKitContainerProvider` before
XCTest boots. A TestAction command-line argument alone did not prevent that
crash. The scheme now also sets `WALKSGPX_DISABLE_CLOUDKIT=1`, and the store
factory detects both that variable and `XCTestConfigurationFilePath`. A later
focused run on a second simulator booted XCTest and ran the in-memory Core Data
tests, confirming the host guard worked. After correcting the helper test's
environment assumptions, the full simulator suite passed 56/56 tests. The
first helper test failure was an
incorrect baseline assertion: it accidentally read the real XCTest environment
and therefore got the intentionally disabled result. When testing production
configuration, pass an explicit empty environment and arguments instead of
inheriting the test process. Keep the override out of Run/Profile/Archive
actions; production device and Mac launches continue using CloudKit.

Do not overlap simulator test runs against the same destination. An earlier
test operation remained alive while waiting for Xcode's `simctl diagnose`
collection (which can wait up to 600 seconds), and a second run against the
same simulator made output and partial `.xcresult` bundles ambiguous. Before
retrying, inspect active `xcodebuild test` and `simctl diagnose` processes; stop
only confirmed stale jobs, then run one focused test invocation and wait for
its terminal result. A partial `.xcresult` without `Info.plist` is not a
completed test report. Keep simulator startup failures separate from test
assertions and verified CloudKit failures.

## Device smoke test

Select the iOS scheme and connected iPhone, set the signing team, build and
run. Verify the app installs with a valid executable, requests Health access,
shows progress, and saves route walks. Check a known long GPS-recorded walk
with a preview and export a GPX file, then inspect its track points. For a
long initial history, keep the app foregrounded while it scans; background
refresh time is not guaranteed.

For CloudKit Core Data, verify both signed targets use the same container and
private database, the Mac is signed into the same Apple Account, and the
iPhone's existing route count and sample route IDs/point counts arrive in the
Mac's local list. Then save a new route and verify it arrives too. Allow for
asynchronous export/import, and inspect CloudKit/Core Data events and logs if
it stalls. Keep the separate iCloud Drive fallback until the first historical
round trip is verified.

On the physical-device check, the first screenshot immediately after launch
showed the empty state; after the asynchronous store/history load settled, the
same installed app displayed all 2,786 retained routes. Wait for the app's
loaded count before diagnosing loss or starting a full-history repair. The
device's SQLite file was roughly 957 MB and actively had a WAL; `devicectl`
file-service socket failures produced a truncated copy. A failed copy is not
a database-integrity result—never query it as authoritative. Do not interrupt
`devicectl device process launch --console` with Ctrl-C while trying to stop
log observation: that command forwards signals to the app and terminates it.
Use a non-console launch plus screenshots/process diagnostics instead.

The iPhone's persisted `hasConnected`/anchor/backfill metadata and pending
route count can explain why a run is incremental, but do not expose anchor
bytes or workout IDs. Growth in the app container's `WalksGPX_ckAssets` is
not a completed CloudKit export signal. A true cross-device result still
requires observing successful source export and destination import events,
then verifying Mac-side route count and representative payloads.

Verified 2026-10-11: after installing the signed build, the phone displayed
2,786 walks. The Mac imported 2,681 and then appeared idle; reopening the Mac
app triggered another import and brought its local Core Data count to 2,786.
Its SQLite integrity check passed and the known Oct 11, 140-minute route was
present with 7,511 points. One import event initially had a null end date,
which meant it was still running; later successful import events completed.
This is the first confirmed iPhone-to-Mac round trip for this prototype.

A signed Mac-only launch confirmed the expected team/container entitlements
and successful local CloudKit store setup/import events, but the import
contained zero objects. The iPhone was unavailable, so this is evidence the
Mac-side setup can run, not evidence that the source uploaded or that a
cross-device round trip succeeded. Check the source export event before
changing a destination that has a successful zero-object import. Avoid using
private `ANSCK*` SQLite table layouts as a product API; prefer the documented
container event request/notifications and unified logs.

For iCloud Drive export, verify the signed app includes the
`iCloud.io.ponti.walksgpx` ubiquity-container entitlement, that Files shows
**Walks GPX**, and that `manifest.json` references every
`walk-<uuid>.gpx` file. Local file creation is not proof of remote delivery.

Do not commit `DerivedData`, `xcuserdata`, signing identities, provisioning
profiles, or environment secrets. `.gitignore` covers common local artifacts;
the project file, schemes, package resolution, and Lottie JSON are intentional
tracked inputs.
