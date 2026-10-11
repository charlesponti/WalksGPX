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
`NSPersistentCloudKitContainer` (`Shared/WalkStore.swift:54-65`).

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

The project retains iCloud entitlement entries in its entitlements, but the
current store is explicitly local. Entitlements alone do not make Core Data
cloud-synchronized (`iOS/WalksGPX.entitlements:1-9`,
`macOS/WalksGPX.entitlements:1-7`, `Shared/WalkStore.swift:54-65`).
