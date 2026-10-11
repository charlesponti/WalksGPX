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

# macOS GPX workflow

The Mac app is a file organizer/export surface; it does not read HealthKit.
Use the iPhone app to sync routes, then share GPX files to the Mac or open
existing GPX files there (`README.md:5-7`).

1. In the Mac app, choose **+** and select one or more `.gpx` files.
2. Select a walk in the sidebar.
3. Choose **Save GPX…**, choose a destination and filename, and save.

The importer requests security-scoped access, reads the file into memory, and
stops access after reading (`macOS/ContentView.swift:43-50`). The Save panel
writes the selected bytes to the destination (`macOS/ContentView.swift:65-73`).
GPX parsing/validation and map rendering are not implemented; imported data is
preserved as bytes. The Mac view also lists routes found by `WalkStore` when
available (`macOS/ContentView.swift:51-63`), but that store is local to the
Mac install and does not automatically mirror the iPhone store.
