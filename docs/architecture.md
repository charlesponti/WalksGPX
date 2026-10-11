---
title: System architecture
summary: Maps the iOS HealthKit reader, shared persistence and GPX code, and macOS file workflow.
type: architecture
status: active
owner: charlesponti
tags: [architecture, ios, macos]
related: [healthkit-sync.md, persistence.md, gpx-routes.md, macos-workflow.md]
updated: 2026-10-11
---

# System architecture

## Layers and targets

WalksGPX is a SwiftUI app with two independently built application targets and
one iOS unit-test target. XcodeGen describes targets, bundle IDs, deployment
versions, resources, and the Lottie package in `project.yml:1-60`.

- **iOS app** (`iOS/`): requests read access to walking workouts and workout
  routes, queries HealthKit, stores route walks locally, shows sync progress
  and map previews, and exports GPX through the share sheet. Entry points and
  UI state are in `iOS/ContentView.swift:108-220`; HealthKit and background
  sync live in `iOS/HealthKitService.swift:43-345`.
- **Shared code** (`Shared/`): `WalkRoute` and `RouteLocation` define the
  portable value model (`Shared/WalkRoute.swift:3-31`); `WalkStore` provides
  local Core Data persistence (`Shared/WalkStore.swift:23-127`); `GPXExporter`
  serializes routes (`Shared/GPXExporter.swift:3-23`); the versioned
  `manifest.json` model and UUID file naming live in
  `Shared/ICloudExportManifest.swift:3-101` and
  `Shared/ICloudExportConfiguration.swift:1-11`.
- **macOS app** (`macOS/`): imports GPX files or reads locally persisted routes
  when available, then presents a Save panel (`macOS/ContentView.swift:14-74`).
  macOS itself cannot read the iPhone's HealthKit database, so it is not the
  source of workout data (`README.md:5-7`).
- **Tests** (`Tests/SyncStateStoreTests.swift:5-104`): cover sync-state
  persistence/compatibility and progress math. They do not exercise HealthKit
  or route-query behavior.

## Data flow

On iPhone, HealthKit workout samples are merged from pending retry IDs, a
one-time historical scan, and the anchored delta. Route samples are queried
per workout; location callbacks may arrive in batches and multiple route
series are combined. Successfully read routes are persisted before the sync
anchor is committed (`iOS/HealthKitService.swift:94-165`, `264-307`). This
ordering allows a failed route/database operation to be retried instead of
advancing past unsaved data. Details: [HealthKit sync](healthkit-sync.md).

The iOS app mirrors local routes to the user's visible iCloud Drive `Walks GPX`
folder as UUID-named GPX files plus `manifest.json`. Core Data remains the
source of truth; iCloud is a retryable file mirror. Agents can read the
manifest and its relative GPX filenames from that folder. The Mac's Core Data
store is still local and does not mirror the phone database. Export behavior
is implemented in `iOS/ICloudGPXPublisher.swift:8-214` and its target metadata
in `iOS/Info.plist:15-34`.

## Operational boundaries

HealthKit permissions are controlled by iOS and read denial cannot be
reliably distinguished from an empty result by the app. Background refresh is
best-effort and scheduled no earlier than 15 minutes after a sync
(`iOS/HealthKitService.swift:318-345`). XcodeGen is the project configuration
source; the checked-in `.xcodeproj` is generated output and useful for opening
in Xcode.

Read next: [sync pipeline](healthkit-sync.md), [storage](persistence.md),
[route and GPX representation](gpx-routes.md), and [development workflow](development.md).
