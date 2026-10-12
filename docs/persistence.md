---
title: Local persistence
summary: Describes the Core Data route store and durable HealthKit synchronization state.
type: reference
status: active
owner: charlesponti
tags: [core-data, persistence, sync]
related: [architecture.md, healthkit-sync.md, gotchas.md]
updated: 2026-10-11
---

# Persistence and cross-device sync

## Route store

`WalkStore` creates an in-code Core Data model with one `PersistedWalk` entity
and attributes `id`, `startDate`, `endDate`, optional `locationsData`,
optional `routeAvailable`, and optional `routeLookupComplete`
(`Shared/WalkStore.swift`). Locations are JSON-encoded into a binary attribute.
Production targets use `NSPersistentCloudKitContainer` with the shared
`iCloud.io.ponti.walksgpx` private database. Each app installation keeps its
own SQLite replica at `Library/Application Support/WalksGPX.sqlite`; Core Data
mirrors saves and imports records in the background. The explicit URL keeps
the existing iPhone store in place when mirroring is enabled. Unit tests use
an in-memory store and deliberately omit CloudKit options.

Saving workout metadata upserts by UUID without replacing an existing route;
route saves encode off the main actor and upsert the same UUID. Deletion also
throws. `fetchRouteSummaryPage` projects only metadata properties through a
background context and uses a stable date/UUID keyset cursor; it never asks
Core Data to fetch the location blob. A nil `routeAvailable` on a legacy row
means route-bearing. `routeLookupComplete` separates an unknown route lookup
from a confirmed no-route result: new metadata-only rows start with `false`, a
successful lookup with no route sets it to `true` while keeping
`routeAvailable=false`, and saving a route sets both flags to `true`. Existing
legacy `routeAvailable=false` rows are treated as already checked so they do
not trigger repeated HealthKit reads; “Import All History” is the explicit
retry path. Store readiness is asynchronous;
sync waits for it, and a load error prevents writes (`Shared/WalkStore.swift:27-31`,
`81-105`).

## Sync state

The HealthKit anchor and pending HealthKit route-lookup UUIDs are serialized
together in `UserDefaults`. The same state also holds a distinct iCloud export
outbox for route UUIDs and deletion tombstones, plus a one-time manifest
bootstrap marker. The store supports legacy separate keys and resettable flags
for the first-history scan and route batch repair (`iOS/SyncState.swift`).
`reset()` resets sync metadata only; it does not delete Core Data walks. The
one-time route-repair pass queues only explicitly route-less rows; it must not
re-read the archive's already persisted route blobs.

## Durability and device implications

Workout summaries are persisted before route queries; each readable route is
upserted before committing the latest HealthKit anchor
(`iOS/HealthKitService.swift`). This protects both metadata and completed route
work when a later workout fails. Local Core Data data normally
survives app relaunch and app updates, but uninstalling the app can remove its
sandbox. CloudKit mirroring provides the app-to-app cross-device path; the
iCloud Drive GPX mirror remains an independent user/agent-facing file export.
Neither a local save nor a GPX file write proves that the corresponding CloudKit
replica has arrived on another device.

### Persistence repair in build 2

Build 1 constructed `NSPersistentStoreDescription` without assigning its URL.
That left routes non-durable while the HealthKit anchor still persisted in
`UserDefaults`, making a later refresh appear to contain only recent changes.
Build 2 assigns the SQLite URL and intentionally advances the history-backfill
marker from `v1` to `v2`, causing one safe full HealthKit re-import. The
explicit **Import all history** action can repeat that recovery without
resetting the anchor or deleting existing routes (`iOS/SyncState.swift:20-103`,
`iOS/HealthKitService.swift:87-195`).

CloudKit entitlements alone do not enable Core Data mirroring: the persistent
store must also have `NSPersistentCloudKitContainerOptions`. CloudKit-backed
Core Data is not a shared SQLite file; each device reads its local replica.
The Mac refreshes its list on remote-store-change notifications and when it
returns to the foreground so an asynchronous import appears in the UI
(`macOS/ContentView.swift`).

A separate file mirror exports GPX and a manifest into the user-visible iCloud
Drive folder named `Walks GPX`; it does not read from or initialize the
CloudKit Core Data schema (`iOS/ICloudGPXPublisher.swift`). Keep these paths
conceptually separate: CloudKit is structured app sync; iCloud Drive is the
portable export for Finder, Files, and agents.

### Prototype rollout and real-device verification

This is a personal prototype with one existing source store (the iPhone) and
an empty Mac store. Keep the iPhone SQLite URL stable, enable mirroring on that
store, and let Core Data export the existing rows. Avoid creating the same
walks independently on the Mac during first sync; that can create duplicate
managed objects because a CloudKit-compatible model cannot rely on a unique
constraint for deduplication. A generalized migration framework is not
required for this rollout.

Keep the iCloud Drive export as a recoverable copy until the same-account Mac
has imported the historical routes. Compare source and destination route
counts and inspect several IDs, dates, and point counts; then add a new route
on iPhone and verify its arrival on Mac. Simulator unit tests only verify
configuration and local store behavior, not CloudKit account provisioning,
schema initialization, initial historical export, or cross-device delivery.
Sync is eventual and system-managed, so allow time, keep both devices online,
and inspect Core Data/CloudKit logs before treating a delay as data loss.

`WalkStore` posts persistent-store remote-change notifications and enables
persistent history tracking. Both app targets observe those notifications
and refetch the local store so an import finishing after initial launch is
visible. In-memory tests deliberately disable CloudKit to avoid contacting an
account or development schema.

The manifest is a derived index, not another source of truth. It contains
schema version 1, generation time, and sorted walk entries with UUID, relative
filename, date range, and point count (`Shared/ICloudExportManifest.swift`).
Recorded GPS routes are treated as immutable: ordinary HealthKit syncs enqueue
only newly saved route UUIDs and HealthKit deletions. The export journal is
stored alongside the HealthKit anchor in `UserDefaults`; enqueue an export
before saving the route, and acknowledge it only after the GPX file and
manifest update succeed. Deletions use durable UUID tombstones so a relaunch
can finish removing both the GPX and its manifest entry. A retry therefore
replays only unfinished work, not the complete history.

On upgrade, a one-time metadata-only check compares the local route UUID set
with the manifest and checks that listed files exist. If they match, the app
adopts the existing export without loading route blobs. If the manifest is
missing or incomplete, a paged full reconciliation bootstraps it. Afterward,
full reconciliation is reserved for the explicit **Repair iCloud Drive
folder** action; it must not be called on routine launch or after every
unchanged HealthKit anchor query. This repair is authoritative and prunes only
app-generated `walk-*.gpx` files absent from the Core Data route set. A
malformed manifest can be rebuilt, while an unsupported future schema is
preserved and reported instead of overwritten (`iOS/ICloudGPXPublisher.swift`).
Progress for normal runs counts queued changes, not all archived routes.
