---
title: Route model and GPX export
summary: Defines route point requirements, GPX serialization, filenames, and map-preview behavior.
type: reference
status: active
owner: charlesponti
tags: [gpx, routes, export]
related: [architecture.md, persistence.md, macos-workflow.md]
updated: 2026-10-11
---

# Route model and GPX export

## Model

`WalkRoute` contains a UUID, start/end dates, and ordered `RouteLocation`
values (`Shared/WalkRoute.swift:3-31`). A location has latitude, longitude,
optional elevation, and timestamp. HealthKit converts `CLLocation` values to
this platform-neutral representation (`iOS/HealthKitService.swift:286-299`).
At least two points are required for a route (`iOS/HealthKitService.swift:295-299`).

## GPX output

`GPXExporter.data(for:)` writes UTF-8 GPX 1.1 XML with a track name based on
the route start time, one track segment, and a `trkpt` per location
(`Shared/GPXExporter.swift:3-23`). Coordinates are latitude/longitude
attributes; elevation is omitted when nil; each point timestamp and route
metadata time use ISO-8601 with fractional seconds. The filename format is
`walk-yyyy-MM-dd-HHmm.gpx` (`Shared/WalkRoute.swift:14-23`).

The exporter currently interpolates numeric values directly into XML and does
not include distance, duration, workout source, heart rate, or privacy
redaction. Exported coordinates are sensitive location history; choose a
trusted share destination.

## Map preview

The iOS preview filters non-finite and out-of-range coordinates, draws a
MapKit polyline only when at least two valid coordinates remain, and computes
a padded region from their bounds (`iOS/ContentView.swift:45-105`). A route
with one valid point or invalid coordinates displays “No GPS route preview”.
The preview is non-interactive (`interactionModes: []`).
