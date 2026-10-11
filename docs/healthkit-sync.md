---
title: HealthKit synchronization
summary: Specifies historical backfill, anchored updates, route retrieval, retries, and checkpoint behavior.
type: reference
status: active
owner: charlesponti
tags: [healthkit, sync, ios]
related: [architecture.md, healthkit-access.md, persistence.md, gotchas.md]
updated: 2026-10-11
---

# HealthKit synchronization

## Inputs and state

The service reads walking workouts and workout-route series. It persists an
`HKQueryAnchor`, a set of workout UUIDs whose routes need retrying, and the
last sync date in `UserDefaults` (`iOS/SyncState.swift:14-109`). Legacy anchor
and date keys are read when the consolidated state is absent. A separate
connection flag controls whether the UI offers a reconnect flow.

## One-time history and later deltas

Each sync combines (1) pending route workouts, (2) a full walking workout
sample query until `healthKit.fullHistoryBackfill.v1` is marked complete, and
(3) the anchored added/deleted workout result. UUID-keyed merging prevents
duplicate work; deleted UUIDs are removed from pending IDs and local storage
(`iOS/HealthKitService.swift:94-122`, `202-262`). The one-time full-history
pass exists because an existing anchor can omit older data that needs repair.
It can be expensive for a large HealthKit history.

The full-history-complete flag is written only after route processing, local
deletions, and anchor persistence complete (`iOS/HealthKitService.swift:137-165`).
If the process fails first, the next sync will scan the history again. This
favors completeness over minimizing repeated work.

## Route extraction and writes

At most four workout route lookups run concurrently. Each workout may have
multiple `HKWorkoutRoute` series. Each series query emits one or more location
batches; `RouteBatchAccumulator` joins batches across every series, sorts by
timestamp, and finishes only when all series report completion
(`iOS/HealthKitService.swift:6-41`, `264-307`). Fewer than two points are not
exportable and are treated as pending.

Each complete route is saved independently before the sync anchor advances
(`iOS/HealthKitService.swift:137-165`). This makes progress durable during
long backfills. If a route has no available route series, its UUID remains in
the retry set. Successful retries remove the UUID. The UI reports pending
route counts and a diagnostic message (`iOS/HealthKitService.swift:165-175`).

Newly saved routes are mirrored to iCloud Drive in groups of 100. After local
HealthKit work completes, a full snapshot reconciliation repairs missing GPX
files and manifest entries and removes generated exports for deleted workouts
(`iOS/HealthKitService.swift:124-187`, `iOS/ICloudGPXPublisher.swift:45-92`).
iCloud errors do not prevent local anchor advancement; startup and later sync
reconcile from Core Data (`iOS/HealthKitService.swift:193-229`).

## Cancellation, errors, progress

Progress counts completed workout-route attempts against the workout count,
not points or bytes (`iOS/HealthKitService.swift:120-158`;
`iOS/SyncState.swift:4-12`). On cancellation, already saved routes remain,
and the anchor is not advanced; the operation can be retried
(`iOS/HealthKitService.swift:137-183`). Store write errors propagate to the
sync catch handler rather than being silently ignored.

Background refresh uses `BGAppRefreshTask`; expiration cancels the running
task. Scheduling is best effort and sets `earliestBeginDate` to 15 minutes,
not a guarantee that iOS will run it then (`iOS/HealthKitService.swift:318-345`).

## Limits

HealthKit read authorization is intentionally read-only. The app cannot prove
that a user granted read access from the authorization request's success
alone. A workout with duration/distance can legitimately have no saved GPS
route. Simulator testing cannot validate the user's actual HealthKit dataset.
Local iCloud write completion also does not guarantee remote upload completion;
the UI checks ubiquitous-item upload metadata and reports pending delivery
(`iOS/ICloudGPXPublisher.swift:198-204`).
