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
  routes, queries HealthKit, stores workout summaries/routes locally, shows sync
  progress, and exports a selected GPX through the share sheet. Entry points and
  UI state are in `iOS/ContentView.swift:108-220`; HealthKit and background
  sync live in `iOS/HealthKitService.swift:43-345`.
- **Shared code** (`Shared/`): `WalkRoute` and `RouteLocation` define the
  portable value model (`Shared/WalkRoute.swift`); `WalkStore` provides local
  Core Data replicas mirrored to the user's CloudKit private database on both
  app targets (`Shared/WalkStore.swift`); `GPXExporter`
  serializes routes on demand (`Shared/GPXExporter.swift:3-23`); the shared
  paged library, compact row, selected detail loader, and MapKit route view
  live in `Shared/WalkCard.swift`; the versioned
  `manifest.json` model and UUID file naming live in
  `Shared/ICloudExportManifest.swift:3-101` and
  `Shared/ICloudExportConfiguration.swift:1-11`.
- **macOS app** (`macOS/`): reads routes imported into its local Core Data
  replica from CloudKit, can import GPX files, and presents a Save panel
  (`macOS/ContentView.swift`). macOS itself cannot read the iPhone's HealthKit
  database, so it is not the source of workout data (`README.md`).
- **Tests** (`Tests/`): cover sync-state persistence, route processing, GPX
  serialization, Core Data local/store configuration, manifest operations,
  progress math, and selected UI state. They do not prove physical HealthKit
  access, CloudKit account/schema setup, or cross-device delivery.

## Data flow

On iPhone, HealthKit workout samples are merged from pending retry IDs, a
one-time historical metadata scan, and the anchored delta. Workout metadata is
persisted even when route access is pending. Route samples are queried only for
unpersisted routes; location callbacks may arrive in batches and multiple
route series are combined. Metadata, routes, and deletions are persisted before
the sync anchor is committed (`iOS/HealthKitService.swift`). This
ordering allows a failed route/database operation to be retried instead of
advancing past unsaved data. Details: [HealthKit sync](healthkit-sync.md).

The iOS and macOS targets each keep a local Core Data SQLite replica and use
`NSPersistentCloudKitContainer` to mirror structured walk summaries and optional route payloads through the
same private CloudKit database. The Mac refetches after remote store changes
and on foreground activation. Separately, the iOS app mirrors local routes to
the user's visible iCloud Drive `Walks GPX` folder as UUID-named GPX files plus
`manifest.json`. Ordinary sync exports only newly saved routes and queued
deletions from a persistent outbox; route files are immutable after creation.
A one-time completeness check adopts an existing full manifest without reading
route payloads. Full archive reconciliation runs only for initial bootstrap or
the explicit repair action. That file mirror is for Finder/Files and agents;
it is not the app-to-app Core Data sync. The HealthKit anchor and connection
state remain iPhone-local. See [persistence](persistence.md) and
[macOS workflow](macos-workflow.md).

## Operational boundaries

HealthKit permissions are controlled by iOS and read denial cannot be
reliably distinguished from an empty result by the app. Background refresh is
best-effort and scheduled no earlier than 15 minutes after a sync
(`iOS/HealthKitService.swift:318-345`). XcodeGen is the project configuration
source; the checked-in `.xcodeproj` is generated output and useful for opening
in Xcode.

Read next: [sync pipeline](healthkit-sync.md), [storage](persistence.md),
[route and GPX representation](gpx-routes.md), and [development workflow](development.md).
