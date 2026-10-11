# Walks GPX

A tiny SwiftUI companion app for exporting walking routes from HealthKit as GPX.

## Important platform detail

Apple does not let macOS apps read the HealthKit store. The iOS target is therefore the HealthKit reader and GPX exporter; the macOS target imports those GPX files and saves them wherever you need.

## Build

1. Install Xcode and an Apple Developer signing team.
2. Run `xcodegen generate` in this directory.
3. Open `WalksGPX.xcodeproj`.
4. Select your team for the iOS target and enable the HealthKit capability if Xcode asks.
5. Run the iOS target on an iPhone with walking routes in Health, tap **Connect Health**, and share a GPX file to the Mac.
6. Run the macOS target and import the GPX file.

The iOS app requests only read access. It uses an anchored HealthKit workout query so the first sync reads the history and later syncs process only changes. Routes are saved as they arrive; workouts whose route is not ready are kept in a durable retry queue. A scheduled `BGAppRefreshTask` retries incremental sync in the background when iOS grants runtime and cancels cleanly if the system expires the task.

## Local persistence

Walks are persisted in a local Core Data store on the iPhone. This keeps HealthKit sync reliable even when iCloud is unavailable; GPX files are shared directly to the Mac from the iPhone.

## Tests

The `WalksGPXTests` target covers sync-state persistence and progress behavior. Run it with `xcodebuild test -scheme 'WalksGPX iOS'` on an iOS Simulator. HealthKit and CloudKit require device/system integration testing because the simulator cannot provide the user’s real HealthKit store.

## Documentation

See [`docs/architecture.md`](docs/architecture.md) for the system map,
[`docs/healthkit-sync.md`](docs/healthkit-sync.md) for synchronization
semantics, and [`docs/gotchas.md`](docs/gotchas.md) for important limitations
and troubleshooting. The other `docs/` references cover access, storage, GPX,
the Mac workflow, and development.
