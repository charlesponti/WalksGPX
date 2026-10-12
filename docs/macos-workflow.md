---
title: macOS GPX workflow
summary: Describes importing, selecting, and saving route GPX files in the Mac app.
type: guide
status: active
owner: charlesponti
tags: [macos, gpx, export]
related: [architecture.md, gpx-routes.md, development.md]
updated: 2026-10-11
---

# macOS walks and GPX workflow

The Mac app does not read HealthKit. Its Core Data store is a local replica
that receives walks through the shared CloudKit private database. The iPhone
also writes a separate GPX + manifest export to the visible iCloud Drive folder
named **Walks GPX**. That folder remains useful in Finder/Files and to agents,
but the Mac app's normal walk list comes from its Core Data replica, not from
scanning the files. See [persistence](persistence.md) for the distinction and
first-sync verification steps.

The Mac refreshes its local route list after persistent-store remote-change
notifications and when the app returns to the foreground. CloudKit arrival is
asynchronous; allow time for the iPhone export and Mac import, and keep both
devices signed into the same Apple Account with network access. A local save on
iPhone is not proof that the Mac has imported the record yet.

The signed iPhone-to-Mac round trip was verified on 2026-10-11. Both local
stores reached 2,786 `PersistedWalk` rows; the Mac had 889,309,502 bytes of
route payload and passed SQLite integrity checking. The known Oct 11 walk was
present on Mac at 7,511 points. The first Mac import paused at 2,681 rows;
reopening the app caused a subsequent import to bring in the remaining 105.
If the destination appears to stall below the source count, foreground or
reopen it once, then verify the count and a representative route before
diagnosing CloudKit as failed.

Core Data's `ANSCK*` SQLite metadata tables can help with a one-off local
diagnosis, but they are private implementation details; do not build product
logic or durable support procedures around their schema. Prefer
`NSPersistentCloudKitContainerEventRequest`, event notifications, and the
unified logs when exposing supported diagnostics.

The Mac and iPhone use the same compact walk row: time, duration, and route
availability. The date appears once in the day section header. Rows never
fetch route points or request map imagery. Selecting a row loads a single
interactive MapKit detail with the route fitted to native map tiles; GPX is
serialized only after export is chosen. On Mac, the floating sidebar navigates
months grouped under years, and the middle column shows only that month's
walks. Wide windows show the month rail, walk list, and detail together; the
system collapses navigation for narrow windows.

To export a synced walk from the Mac:

1. Select a walk and choose **Export GPX…** in its detail, or use the row
   context menu/keyboard command when available.
2. Choose a destination and filename in the Save panel.

To import a standalone GPX file:

1. Choose **+** and select one or more `.gpx` files.
2. Find the imported file's card and choose its download button.
3. Choose a destination and filename in the Save panel.

The importer requests security-scoped access, reads the file into memory, and
stops access after reading (`macOS/ContentView.swift`). The Save panel writes
the selected bytes to the destination (`macOS/ContentView.swift`).
Parsing/validation of standalone imported GPX files is not implemented; their
bytes are preserved and re-exported as-is. Synced walk maps use route points
from the local Core Data store. File-imported walks are not inserted into Core
Data or CloudKit.

## Large-history performance and pagination

The former Mac implementation fetched every Core Data row, decoded every
`locationsData` JSON blob into route points, converted every route into GPX
`Data`, and retained those payloads in SwiftUI state. This repeated on
startup, foregrounding, and remote-store notifications. `List` may virtualize
row rendering, but cannot help if the app has already materialized every
route and GPX payload.

A live sample on 2026-10-11 measured the main thread inside
`WalkStore.fetchRoutes()` → `PersistedWalk.route` → `JSONDecoder.decode` for
the whole 3-second sample, while CPU stayed near 100%. Physical footprint
peaked around 2.3 GB. No macOS crash report was present, so the decode/memory
pressure and UI stall are confirmed; an OS memory kill is plausible but not
proven. Treat repeated crashes reported by a user as likely related until
this eager path is removed.

The Mac builds a month index from `startDate` values only, then queries the
selected month for lightweight summaries (`id`, start/end dates, route state),
100 rows at a time through a background context. These queries leave
`locationsData` out of month navigation, filtering, and list paths. The next
page is requested as the selected month's list reaches its loading row. Only
the selected detail loads route points; export serialization runs off the main
actor after explicit user action. Remote-change notifications refresh summary
metadata without clearing the current selection. The records remain in Core
Data—the month view is a browsing boundary, not a sync or storage boundary.
`fetchBatchSize` alone would not solve the issue if every object were
immediately decoded and retained.

The floating sidebar is provided automatically by SwiftUI's
`NavigationSplitView` on the current Liquid Glass-era macOS design; there is
no separate floating-sidebar modifier. The app uses `.listStyle(.sidebar)`
for the year/month selector and does not add its own glass material. Apple
introduced this treatment in the macOS Tahoe (26) / Xcode 26 design guidance;
the public docs do not describe a distinct macOS 27 sidebar API. See Apple's
[SwiftUI navigation split view](https://developer.apple.com/documentation/swiftui/navigationsplitview),
[sidebar HIG](https://developer.apple.com/design/human-interface-guidelines/sidebars),
and [WWDC25 design session](https://developer.apple.com/videos/play/wwdc2025/323/).

`WalkStoreTests` cover stable cursor ordering (including equal-date walks),
month grouping and counts, month-scoped summary queries, and prove summary
queries can read a deliberately invalid route blob without decoding it.
