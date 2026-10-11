---
title: HealthKit and app gotchas
summary: Catalogs failure modes that can make sync appear empty, incomplete, or unreliable.
type: reference
status: active
owner: charlesponti
tags: [gotchas, healthkit, troubleshooting]
related: [healthkit-sync.md, healthkit-access.md, persistence.md, gpx-routes.md]
updated: 2026-10-11
---

# HealthKit and app gotchas

## A workout is not a GPS route

HealthKit can return workout metadata without any `HKWorkoutRoute` series.
Duration and distance do not imply GPS points. The app needs at least two
locations to create an exportable `WalkRoute`; otherwise it retries the workout
and eventually reports that the workout may have no route
(`iOS/HealthKitService.swift:137-146`, `165-175`, `295-299`). A blank map is
therefore different from a map-rendering failure: inspect the saved point
count first.

## Read access is intentionally ambiguous

The app reads only; HealthKit does not let an app determine whether read
permission was denied. A successful authorization callback and a persisted
“connected” flag do not prove read access. Empty results require checking
Health settings and whether matching route samples exist. See
[HealthKit access](healthkit-access.md).

## Anchors do not replace a history repair

Anchored queries return changes since a checkpoint, not a guaranteed full
inventory. A stale anchor can make old workouts invisible to incremental
sync. The implementation therefore performs one full history query on first
sync and merges it with pending and anchored records
(`iOS/HealthKitService.swift:94-122`, `252-268`). Use the toolbar's **Import
all history** command whenever an explicit repair is needed; it leaves saved
routes in place and re-upserts by workout UUID.

## A sync anchor is not route-store proof

The HealthKit anchor is stored independently of Core Data. If routes are
missing while the anchor remains, an incremental query may return only a new
walk and make a historical import look unavailable. A durable Core Data SQLite
URL is therefore mandatory, and build 2 advances the one-time backfill marker
to recover installations affected by the earlier in-memory description
(`Shared/WalkStore.swift:54-78`, `iOS/SyncState.swift:25-92`).

## Route callbacks are batched and routes can be multiple

`HKWorkoutRouteQuery` can yield multiple callbacks for one route, and a
workout can have multiple route series. Saving only the first callback or
finishing at the first series truncates tracks. The accumulator waits for all
series, concatenates batches, and sorts by timestamp
(`iOS/HealthKitService.swift:6-41`, `264-307`).

## Never commit the anchor ahead of route data

If a sync advances its anchor before route writes finish, later incremental
queries may never revisit the omitted routes. WalksGPX persists each complete
route first and advances the anchor only after route processing/deletion
finishes (`iOS/HealthKitService.swift:137-165`). Core Data write errors must
remain visible to this sequencing logic (`Shared/WalkStore.swift:88-120`).

## Progress and background expectations

Progress measures workouts attempted, not GPS point retrieval or bytes. A
large one-time scan can take a while. iOS background refresh is discretionary;
the requested earliest time is not a start deadline
(`iOS/HealthKitService.swift:318-345`). Keep the app open for a large initial
backfill.

## Local database is not cross-device sync

The app uses local Core Data despite CloudKit entitlements. The Mac's local
database does not receive the iPhone database. The iPhone now mirrors route
GPX files and a manifest to iCloud Drive; this is file-level export, not Core
Data synchronization (`Shared/WalkStore.swift:54-65`,
`iOS/ICloudGPXPublisher.swift:45-92`). Files appear only after iCloud uploads
them, so a successful local write can still be waiting for delivery. Keep the
phone and Mac signed into the same Apple Account with iCloud Drive enabled.
Uninstalling can remove local Core Data; the iCloud copy remains subject to
the user's iCloud account and deletion choices.

The app-visible folder is the ubiquity container's `Documents` directory; the
container metadata supplies the displayed folder name `Walks GPX`. Do not add
another same-named nested directory. The manifest uses relative UUID-based
filenames so agents can resolve files without depending on a machine-local
absolute path (`Shared/ICloudExportConfiguration.swift:1-11`).

## Test boundary

Current unit tests validate `SyncStateStore` and progress fraction behavior,
not HealthKit queries, route batching, Core Data failure behavior, GPX
conformance, or device installation (`Tests/SyncStateStoreTests.swift:22-103`).
Simulator success cannot substitute for checking real HealthKit permissions
and route availability on an iPhone.
