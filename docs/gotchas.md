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

## Local Core Data is a replica, not the cross-device transport

Each app target has its own local Core Data SQLite store. The configured
`NSPersistentCloudKitContainer` mirrors structured records through the shared
CloudKit private database; do not point both devices at the same SQLite file.
CloudKit entitlements alone are insufficient—the store description must also
have `NSPersistentCloudKitContainerOptions`. The Mac must refresh its local
fetch after remote-store changes and foreground activation because an import
may finish after its first launch fetch.

The iPhone's GPX files and manifest in iCloud Drive are a separate export path,
not proof that CloudKit Core Data has imported the same records. Conversely,
records arriving in the Mac's Core Data store do not require the Mac to scan
that folder. Keep both devices on the same Apple Account and allow for
eventual, system-managed delivery. For this single-user prototype, preserve the
iPhone's existing SQLite URL, avoid independently seeding the Mac during the
initial import, and verify counts plus sample route IDs and point counts.
In-memory tests must omit CloudKit options; otherwise they can contact a real
CloudKit environment and become account/schema-dependent.

### Physical-device diagnostics: distinguish launch from loaded state

An immediate screenshot after launching the iPhone can briefly show the empty
state before the asynchronous store/history load has settled. In this device
check it first showed “No route walks yet,” then later showed the retained
2,786 routes and the in-progress 70-workout retry. Do not treat that first
frame as evidence of data loss; wait for the store fetch and inspect the route
count before initiating a full-history repair.

The app's `Library/Application Support/WalksGPX.sqlite` on this phone is about
957 MB, with a live WAL. `devicectl device copy from` twice failed mid-transfer
with a closed file-service socket, leaving a truncated database copy that
failed SQLite integrity/open checks. Never query a partial copy or treat its
failure as source-store corruption. Prefer app-visible counts and bounded
diagnostics; if a database copy is essential, stop the app cleanly, copy the
SQLite file together with its WAL/SHM state, and verify integrity before any
analysis. Preserve the original on-device store.

The copied app preferences showed `hasConnected`, a saved HealthKit anchor,
and the full-history-backfill marker set, with 70 pending route IDs. These
metadata explain why the app should run incremental/pending work rather than
repeat the full scan. Do not print anchor bytes or route identifiers into
logs. On-device `WalksGPX_ckAssets` growth is only a progress clue; it is not
proof that CloudKit has completed export or that the Mac imported records.
Verify the source CloudKit export event, destination import event, and
destination local count independently.

`devicectl device process launch --console` waits for app termination and
forwards catchable signals to the app. Ctrl-C therefore terminated the
foreground app in this check. For a persistent app, launch without `--console`
and use screenshots, process listings, or non-invasive device diagnostics;
if console attachment is necessary, do not interrupt it as though it were a
detached log tail.

### Verified iPhone-to-Mac CloudKit round trip

On 2026-10-11, the signed iPhone and Mac builds finally converged from zero to
the same **2,786** `PersistedWalk` rows. The Mac store contained 889,309,502
bytes of route payloads and passed SQLite `PRAGMA integrity_check`. The known
Oct 11 walk was present with a 140.7-minute duration and 7,511 decoded points,
matching the iPhone card. The Mac initially plateaued at 2,681 rows with no
new import event; quitting and reopening the Mac app triggered another
CloudKit import, and the remaining 105 rows arrived. A first complete-looking
batch is not enough—compare source/destination counts and representative
payloads, and reopen the destination once if its imports go quiet below the
source count. Treat an import event with no end timestamp as in progress, not
failed. Keep verifying the final event and local data rather than interpreting
temporary CloudKit asset-file counts as completion.

### macOS must not eagerly decode the full route history

With 2,786 synced walks, the Mac's startup/refresh path fetched every row,
decoded every route's `locationsData`, serialized every route again as GPX,
and retained all GPX `Data` in SwiftUI state (`macOS/ContentView.swift:92-108`,
`Shared/WalkStore.swift:183-186`). A live 3-second sample spent all samples on
the main thread in `JSONDecoder.decode` through `PersistedWalk.route`; process
CPU stayed near 100%, and physical footprint peaked around 2.3 GB. This
confirms an expensive UI-blocking load and substantial memory pressure. No
macOS crash report was found, so an OS memory kill is not yet proven; the
user-reported crashes may be caused by this path but should not be described
as a confirmed OOM termination.

`List` is lazy about row views, not about data that the app eagerly put in
`@State`. The current implementation pages lightweight Core Data summaries
(100 rows, stable date/ID cursor), and decodes the route only when that walk is
exported. The regression tests verify same-date page ordering and that summary
fetches succeed even when the route JSON is deliberately invalid. Remote-change
notifications are debounced; refreshes must not decode the entire history.
`fetchBatchSize` alone does not solve the issue if every record is immediately
decoded and retained.

Hosted XCTest has an additional boundary: the app host may launch before the
test bundle and may not have the iCloud container entitlement. A TestAction
command-line argument alone did not suppress the CloudKit initialization
crash in this environment. Provide a test-only environment override as well,
and verify from a fresh crash report or successful XCTest bootstrap that the
host actually honored it. When simulator testing hangs, inspect for other
active `xcodebuild test`/`simctl diagnose` jobs before retrying; overlapping
runs produced ambiguous partial result bundles here.

The app host receives `XCTestConfigurationFilePath`; using that as a test-only
CloudKit-disable signal allowed the focused XCTest suite to bootstrap on a
second simulator. Unit tests of the resolver must pass an explicit empty
environment when asserting normal production behavior, or the XCTest marker
will correctly make the resolver return no CloudKit container.

When refreshing a SwiftUI list after remote imports, use stable domain IDs for
synced rows (the workout UUID), not a fresh random ID on each fetch. Otherwise
selection identity changes during sync and the detail pane can point at a
stale row. Preserve selection by stable ID, but also replace the selected
value with the freshly fetched row; retaining an old value-type selection can
leave the detail pane displaying stale GPX bytes after an update. Coalesce
remote-store-change notifications before refetching large route payloads so a
burst of CloudKit imports does not repeatedly decode the entire history.

The app-visible folder is the ubiquity container's `Documents` directory; the
container metadata supplies the displayed folder name `Walks GPX`. Do not add
another same-named nested directory. The manifest uses relative UUID-based
filenames so agents can resolve files without depending on a machine-local
absolute path (`Shared/ICloudExportConfiguration.swift:1-11`).

## Test boundary

Unit tests validate pure synchronization state, route processing, GPX output,
and Core Data's in-memory persistence/store configuration. They do not prove
CloudKit account provisioning, schema initialization, migration of the
existing route history, or cross-device delivery. Simulator success cannot
substitute for checking real HealthKit permissions/routes on iPhone or a real
CloudKit round trip between the signed phone and Mac apps.
