---
title: HealthKit access and privacy
summary: Explains the requested HealthKit permissions and how to diagnose empty or partial results.
type: guide
status: active
owner: charlesponti
tags: [healthkit, privacy, troubleshooting]
related: [healthkit-sync.md, gotchas.md]
updated: 2026-10-11
---

# HealthKit access and privacy

WalksGPX requests read access only (`toShare: []`) for walking workout
samples and workout-route series (`iOS/HealthKitService.swift:66-82`). The
usage explanation in `iOS/Info.plist:27-28` says that workouts and routes are
read to export them as GPX. HealthKit data remains on-device in the local
Core Data store; the app does not upload it to a service
(`Shared/WalkStore.swift:54-65`).

## Connect and permissions

1. On iPhone, open Walks GPX and tap **Connect Health** (or **Sync Health** if
   already connected).
2. Approve access to Workouts and Workout Routes in Apple's Health permission
   sheet.
3. If results seem incomplete, open Health's Apps and Services settings for
   Walks GPX and verify both categories. Run Sync Health again.

The app persists a `hasConnected` flag so an app restart does not require the
authorization sheet every time (`iOS/SyncState.swift:46-55`). This flag records
that the authorization flow completed; it is not proof that read access was
granted.

## Interpret results carefully

HealthKit intentionally does not expose whether read access was denied:
authorization status for reading is not a reliable way to distinguish denial
from no matching samples. Therefore an empty query can mean no matching data,
no read access, or data not visible to this app. The app can display
troubleshooting guidance but cannot diagnose which cause applies.

Workout metadata is separate from route samples. A long walk with distance and
duration may have no GPS route if the recording source did not save route
points, if Workout Routes access is unavailable, or if route samples are not
visible. Only workouts with at least two route points can produce a meaningful
map preview or GPX track (`iOS/HealthKitService.swift:295-299`,
`iOS/ContentView.swift:81-105`).

The app does not request HealthKit write access, location tracking, or
background location access. Background sync is a best-effort refresh of data
already in HealthKit, not live GPS recording.
