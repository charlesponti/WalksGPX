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

# Local persistence

## Route store

`WalkStore` creates an in-code Core Data model with one `PersistedWalk` entity
and attributes `id`, `startDate`, `endDate`, and `locationsData`
(`Shared/WalkStore.swift:4-20`, `32-52`). Locations are JSON-encoded into a
binary attribute. The store is a local `NSPersistentContainer`, not
`NSPersistentCloudKitContainer` (`Shared/WalkStore.swift:54-78`). It writes to
`Library/Application Support/WalksGPX.sqlite`; the URL is explicit because a
bare `NSPersistentStoreDescription` has no durable file location.

Saving upserts by UUID and throws fetch, encode, and save errors to its caller;
deletion also throws (`Shared/WalkStore.swift:88-120`). Fetches sort newest
first and omit rows whose location payload cannot decode
(`Shared/WalkStore.swift:122-127`). Store load readiness is asynchronous;
sync waits for it, and a load error prevents writes (`Shared/WalkStore.swift:27-31`,
`81-105`).

## Sync state

The anchor and pending route UUIDs are serialized together in `UserDefaults`.
The store supports legacy separate keys and has resettable flags for the
first-history scan and route batch repair (`iOS/SyncState.swift:20-109`).
`reset()` resets sync metadata only; it does not delete Core Data walks.

## Durability and device implications

Routes are saved one at a time as they complete, before committing the latest
HealthKit anchor (`iOS/HealthKitService.swift:137-165`). This protects against
losing completed route work when a later workout fails. Local Core Data data
normally survives app relaunch and app updates, but uninstalling the app can
remove its sandbox. There is no automatic iCloud sync between iPhone and Mac;
export GPX files for transfer.

### Persistence repair in build 2

Build 1 constructed `NSPersistentStoreDescription` without assigning its URL.
That left routes non-durable while the HealthKit anchor still persisted in
`UserDefaults`, making a later refresh appear to contain only recent changes.
Build 2 assigns the SQLite URL and intentionally advances the history-backfill
marker from `v1` to `v2`, causing one safe full HealthKit re-import. The
explicit **Import all history** action can repeat that recovery without
resetting the anchor or deleting existing routes (`iOS/SyncState.swift:20-103`,
`iOS/HealthKitService.swift:87-195`).

The project retains iCloud entitlement entries in its entitlements, but the
current store is explicitly local. Entitlements alone do not make Core Data
cloud-synchronized (`iOS/WalksGPX.entitlements:1-11`,
`macOS/WalksGPX.entitlements:1-9`, `Shared/WalkStore.swift:54-65`). A separate
file mirror exports GPX and a manifest from this local store into the
user-visible iCloud Drive folder named `Walks GPX`; it does not turn Core Data
into a shared database (`iOS/ICloudGPXPublisher.swift:45-103`).

The manifest is a derived index, not another source of truth. It contains
schema version 1, generation time, and sorted walk entries with UUID, relative
filename, date range, and point count (`Shared/ICloudExportManifest.swift:3-89`).
The exporter repairs its contents from Core Data after relaunch or sync. A
malformed manifest can be rebuilt, while an unsupported future schema is
preserved and reported instead of overwritten
(`iOS/ICloudGPXPublisher.swift:106-117`).
