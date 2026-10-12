# Walks GPX

A tiny SwiftUI companion app for exporting walking routes from HealthKit as GPX.

## Important platform detail

Apple does not let macOS apps read the HealthKit store. The iOS target reads HealthKit and saves route records to Core Data; both iOS and macOS targets mirror those records through the same CloudKit private database. Each target has its own local Core Data replica. The iPhone also publishes GPX files and a manifest to iCloud Drive for file access and agent workflows.

## Build

1. Install Xcode and an Apple Developer signing team.
2. Run `xcodegen generate` in this directory.
3. Open `WalksGPX.xcodeproj`.
4. Select your team for the iOS target and enable the HealthKit capability if Xcode asks.
5. Run the iOS target on an iPhone with walking routes in Health and tap **Connect Health**.
6. Open Walks GPX on the Mac using the same Apple Account and wait for the CloudKit-backed walk list to populate. The GPX files and `manifest.json` also appear in the **Walks GPX** iCloud Drive folder, independently of Core Data sync.

The iOS app requests only read access. It uses an anchored HealthKit workout query so the first sync reads the history and later syncs process only changes. Routes are saved as they arrive; workouts whose route is not ready are kept in a durable retry queue. A scheduled `BGAppRefreshTask` retries incremental sync in the background when iOS grants runtime and cancels cleanly if the system expires the task.

## Local persistence

Walks are persisted in local Core Data stores on each platform. `NSPersistentCloudKitContainer` mirrors records through the shared private CloudKit database; delivery is asynchronous. The iCloud Drive publisher is a separate retryable file mirror for GPX routes and `manifest.json`. Keep the iCloud Drive export available as a fallback until the initial historical Core Data sync has been verified on the Mac.

## Tests

The `WalksGPXTests` target covers sync state, route processing, GPX output,
Core Data persistence/store configuration, manifest behavior, and UI state.
Run it with `xcodebuild test -scheme 'WalksGPX iOS'` on an iOS Simulator.
HealthKit permissions and real CloudKit delivery still require device/system
integration testing. The current CloudKit/iCloud storage of HealthKit-derived
data is a private prototype choice and is not App Store-ready; see
[`docs/healthkit-access.md`](docs/healthkit-access.md).

## Documentation

See [`docs/architecture.md`](docs/architecture.md) for the system map,
[`docs/healthkit-sync.md`](docs/healthkit-sync.md) for synchronization
semantics, and [`docs/gotchas.md`](docs/gotchas.md) for important limitations
and troubleshooting. The other `docs/` references cover access, storage, GPX,
the Mac workflow, and development.
