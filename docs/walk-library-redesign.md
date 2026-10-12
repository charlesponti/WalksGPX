---
title: Walk library redesign
summary: Product decisions, implementation boundaries, and verification record for the fast walk library on iPhone and Mac.
type: proposal
status: active
owner: charlesponti
tags: [design, performance, ios, macos]
related: [architecture.md, macos-workflow.md, persistence.md, gpx-routes.md]
updated: 2026-10-11
---

# Walk library redesign

The interactive sketch at `docs/design/walk-library.html` informed the design.
This document records the implementation and the evidence still required for
full release acceptance.

## The job

The app is a personal walking archive. Its first job is to make thousands of
saved walks immediately browsable. Its second is to show the selected route
accurately on a map and make its GPX easy to share. HealthKit, CloudKit, and the
iCloud Drive folder should keep working without making the library feel like a
dashboard of background machinery.

The library must open from locally stored summaries even with no network. A
walk without readable GPS points must still appear as a walk, with its route
state explained in its detail view. A map must never be required to scroll.

## What the current implementation tells us

| Priority | Finding | Evidence | Consequence |
| --- | --- | --- | --- |
| Must fix | Each visible Mac card fetches and decodes its full route and starts a map snapshot. | `macOS/ContentView.swift:353-389`, `Shared/WalkCard.swift:15-74` | Scrolling creates expensive asynchronous work; observed later cards remain on spinners. |
| Must fix | iPhone library retains every full route in view state. | `iOS/HealthKitService.swift:265-266`, `Shared/WalkStore.swift:240-244` | Thousands of route blobs compete with scrolling and sync for memory and main-thread time. |
| Must fix | iPhone card construction serializes GPX for its share action. | `Shared/WalkCard.swift:135` | Export work happens before the person asks to export. |
| Should fix | A landscape map occupies most of every card, repeating the same London tiles. | Current app, October 2026 | The route and metadata are harder to scan; the map has no room to be useful. |
| Should fix | The static map cache is memory-only and small relative to dozens of full-width images. | `Shared/RouteThumbnailRenderer.swift:158-170` | Revisiting cards can trigger more snapshot work. |

Apple's `LazyVStack` creates views as they become needed onscreen, but it does
not make the work inside each view cheap. The bottleneck is the per-row route
decode, GPX creation, and map request, not the choice of scroll container.

## Information architecture

### Mac

1. Month rail: years and months with walk counts.
2. Walk list: compact, scannable entries for the selected month, grouped by day.
3. Detail: one selected walk, with one large map, date/time, duration, route
   state, and GPX export. The detail collapses into navigation on narrow windows.

### iPhone

An inline `Walks` title, month navigation, and the same compact walk entry.
Tap an entry to open a full-screen walk detail with the map and export. Keep
sync progress as a single compact accessory; tapping it opens the detailed
sync report. Do not fill the main screen with repeated status text.

### Walk entry anatomy

One line for the date or start time, one quiet line for duration and route
availability. The selected state identifies the walk. No map, point count,
spinner, or export button in every row. Export remains one tap from the detail;
Mac also offers a row context-menu action and keyboard command. Point count
can live in a technical details disclosure for debugging.

This keeps the same typography, selection, icon treatment, and hierarchy on
both platforms while using each platform's natural navigation geometry.

## Walk detail

The map is the visual centerpiece. Use MapKit's native map and `MapPolyline`
for one selected route so map tiles and route geometry share the same camera.
Fit the camera to the route bounds with padding and allow zoom and pan. Show
start and finish markers only when they help orientation. A route with no valid
points gets a deliberate, quiet unavailable state rather than a permanent
loading indicator. GPX generation starts when Export is chosen.

The first version can show date, time, and duration from existing fields.
Distance and place names are worthwhile later, but require trustworthy
derivation or persisted HealthKit metadata; this design does not fabricate
them from point count.

## Work and data boundaries

- `WalkSummary`: stable ID, start/end, route availability, and any persisted
  display metadata. Query one month/page of summaries without decoding GPS.
- `WalkDetail`: load the selected route's points once in a background context.
  Cancel or replace this load when selection changes. Keep at most the current
  detail and a small nearby cache in memory.
- Map: one interactive MapKit view in the selected detail. No map requests from
  list rows. A transient tile delay affects the detail only; the library stays
  scrollable.
- Export: load the route and serialize GPX after explicit selection. The iOS
  share sheet and Mac Save panel use that result.
- Sync: write routes transactionally, update summaries, and publish changes to
  the list. HealthKit, CloudKit replication, and iCloud Drive export each have
  separate progress and retry states; the main library shows one concise
  status entry.
- The iPhone UI must stop calling `fetchRoutes()` for the entire archive. The
  sync/export pipeline also needs a bounded incremental path, but its work
  should not be owned by the library view.

## States and interaction

| State | Library | Detail |
| --- | --- | --- |
| Launch with saved data | Show summaries immediately. | Preserve or restore selection. |
| Sync in progress | One small status accessory. Existing rows remain usable. | Current route stays visible. |
| No route | Walk remains in list. | Explain that no readable GPS route is saved; export is unavailable. |
| Map tiles delayed | List is unaffected. | Show the route/detail shell and bounded map loading. |
| Offline | Saved walks and GPX export still work. | Map tiles may be unavailable; say so and offer Retry. |
| Empty archive | Explain Connect Health on iPhone or iCloud wait on Mac. | No selected detail. |

No list row has a loading state. A detail load must end in content, an
unavailable state, or a retryable error. Normal sync should never clear the
visible archive.

## Performance and quality bar

Measure on the 2,786-walk archive, not a five-item preview. Targets for the
implementation: first local summaries visible within 500 ms on a warm launch;
continuous scrolling without visible stalls; no GPS decoding or map request
while scrolling; bounded memory that does not rise with total archive size;
selection changes without stale map flashes. These are targets to measure with
Instruments on Mac and iPhone, not claims that the current app meets them.

Before shipping: test light/dark appearance, narrow Mac windows, Dynamic Type,
keyboard selection, VoiceOver order, reduced motion, offline detail, missing
routes, and repeated month switching. Rebuild and relaunch both apps after
implementation, inspect real map alignment, and verify export and sync still
work.

## Implemented architecture

- `WalkStore` persists lightweight workout metadata independently from the
  optional encoded route payload. The additive `routeAvailable` field is
  optional so legacy rows with route blobs remain route-bearing.
- `fetchRouteSummaryPage` fetches only UUID/date/route-state dictionary values
  using keyset pagination. Filtering and month indexing do not decode GPS.
- HealthKit backfill first saves workout metadata, then reads only routes not
  already represented as valid. A route-less workout can later upgrade its
  existing UUID. The HealthKit anchor is written after durable saves/deletions.
- The iPhone and Mac share `WalkLibraryModel`, `WalkLibraryRow`, and
  `WalkDetailScreen`. Each platform pages summaries; only the selected detail
  asks the store for the full route. Export serialization begins on demand.
- The selected detail uses one interactive MapKit map and shared
  `RouteMapGeometry` camera fitting. Library rows make no map/snapshot request.
- iCloud Drive reconciliation reads metadata pages, loads at most 16 routes for
  a write batch, and commits the manifest only after the complete scan. Existing
  generated files are not pruned before a complete replacement set is present.
- Standalone Mac GPX import remains session-only with save-copy behavior.

## Validation record

| Check | Result |
| --- | --- |
| iOS simulator unit suite | 78 tests passed on 2026-10-11, including selected-route loading/export and route-unavailable state; zero failures, skips, or runtime warnings. |
| iOS target build | Passed for the connected iPhone on 2026-10-11; app installed/launched. |
| macOS target build | Passed and app relaunched on 2026-10-11. |
| Mac local archive | 2,786 rows; all 2,786 have route payloads; SQLite integrity is `ok`; date range 2016-09-03 through 2026-10-11. The latest route payload decodes to 7,511 points. |
| iPhone archive parity | The app updated in place and launched; its local store/count was not directly queried, so same-count parity is not re-certified in this pass. |
| Mac CloudKit arrival / performance on full archive | The full archive is visible after relaunch and the selected 7,511-point route is drawn on native tiles. Instruments timing/memory profile remains unmeasured. |
| Simulator visual checks | iPhone 17 simulator empty archive and iCloud retry-error state rendered. Mac accessibility tree exposes grouped days, route status, map, export, and recenter controls. Other appearance/accessibility scenarios remain untested. |
| Instruments scrolling, memory, and warm launch timing | Not measured; 500 ms is still a target, not a claim. |
| Simulator appearance/accessibility states | Not yet fully exercised. |

Do not mark the redesign shipped until these remaining checks are completed.

## Original proposed build order

1. Agree on the Mac and iPhone library/detail composition in the sketch.
2. Create the lightweight shared summary query and remove full-archive route
   loading from iPhone presentation state.
3. Replace map-heavy list cards with shared compact walk entries and selected
   detail navigation.
4. Render the selected route with native MapKit and fit its camera to the route.
5. Move GPX serialization to the export action and bound sync/export work.
6. Add missing/offline/error states and measure the full archive on both apps.

Apple references: [MapKit for SwiftUI](https://developer.apple.com/documentation/mapkit/mapkit-for-swiftui),
[MapPolyline](https://developer.apple.com/documentation/mapkit/mappolyline), and
[lazy stack behavior](https://developer.apple.com/documentation/swiftui/lazyvstack).
