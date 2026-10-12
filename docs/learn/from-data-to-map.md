---
title: From data to map
summary: Follow a route archive through aggregation, smoothing, rendering, testing, and privacy boundaries.
type: guide
status: active
owner: charlesponti
tags: [heatmaps, algorithms, privacy]
related: [../index.md, what-heat-means.md, cells-and-distance.md, ../architecture.md, ../persistence.md]
updated: 2026-10-12
---

# From arithmetic to heatmap

The heatmap is the final picture, not the calculation. Keep those two things separate and the map becomes explainable: every colored cell can point back to a measurement and the route contributions that made it.

## The pipeline

<div class="diagram" role="img" aria-label="Route archive processing stages from source data to rendered heatmap">
  <div class="step"><b>01</b><span>Read one route, preserve walk identity and track gaps</span></div><div class="arrow">↓</div>
  <div class="step"><b>02</b><span>Validate fixes; project coordinates into local metre space</span></div><div class="arrow">↓</div>
  <div class="step"><b>03</b><span>Traverse route segments through cells</span></div><div class="arrow">↓</div>
  <div class="step"><b>04</b><span>Aggregate coverage, walk count, or metres</span></div><div class="arrow">↓</div>
  <div class="step"><b>05</b><span>Normalize values and render over a basemap</span></div>
</div>

The derived data can be small. A route may hold thousands of fixes, but its aggregate contribution might be a set of cell IDs for coverage or a short list of `(cellID, metres)` pairs for distance. With roughly a few thousand walks, processing one route at a time and merging its contributions avoids keeping the entire GPS archive in memory.

## Smoothing is not counting

A raw cell grid can look blocky. Kernel density estimation (KDE) smooths a measured quantity across a radius: nearby cells influence one another, usually with weights that fade with distance. A large radius makes a calm, broad surface; a small radius preserves local variation. QGIS exposes this radius as a key KDE parameter. [QGIS heatmap documentation](https://docs.qgis.org/3.44/en/docs/user_manual/plugins/plugins_heatmap.html).

Keep two layers in mind:

- **Aggregation:** what was counted or measured in each cell.
- **Rendering:** how those values are blurred, normalized, and colored on screen.

If the data say “three walks crossed this cell,” smoothing may spread that influence nearby. It does not mean six walks happened in the red area. Keep a way to inspect the underlying unsmoothed value, and label the radius in metres.

## Color can lie without changing a number

Walking is uneven. A few familiar routes may receive most of the distance, leaving many cells with small values. A linear color scale can make almost everything look cold. A logarithmic or square-root transform can reveal quieter patterns, but it changes the visual spacing between numbers. Always show the legend and name the transform.

For comparison over time, use the same cell system and scale. If every month independently stretches its minimum and maximum to the full color ramp, a quiet month can look as intense as a busy one. That may be useful for within-month shape, but it is not an honest visual comparison of absolute volume.

## Basemap, heat layer, and route layer

The basemap supplies streets and place context. The heat layer supplies your aggregated measure. The individual route layer, when shown, supplies evidence for one selected walk. They are separate layers with separate lifecycles.

Tiles are pieces of the basemap, not pieces of your route. A route heat overlay should be generated from the aggregate grid or raster and aligned to the map’s coordinate system. Cache derived tiles or rendered images by data version, metric, spatial resolution, and style parameters. If the key omits one of those inputs, a stale image can appear after the algorithm or color scale changes.

## Tests that make the picture trustworthy

Test the math on tiny routes whose answers can be worked by hand:

1. One straight segment crossing two cells: its length is conserved across both.
2. The same walk with extra points on that segment: distance does not change materially; visit count does not increase.
3. The same walk repeated on another day: walk frequency increases by one; coverage remains one.
4. A route that crosses a cell, leaves, then returns: frequency for that walk-cell pair remains one; distance includes both pieces.
5. A track gap: no invented connector contributes through the missing area.
6. A route at a cell boundary, a zero-length segment, invalid coordinates, and a long GPS jump: each has a defined result.

The simplest invariant for distance is conservation: total cell metres approximately equal total accepted segment metres. The simplest invariant for visits is uniqueness: each `(walk UUID, cell ID)` contributes at most one. These catch algorithm bugs before screenshots can hide them.

## Keep the source; rebuild the summary

The heat grid is derived data. It can be deleted and rebuilt from routes. This is especially useful while the metric is still being explored: change from square cells to H3, alter resolution, or improve gap handling without treating an old aggregate as truth.

An incremental design can later store a contribution ledger keyed by workout UUID. When a route changes or is deleted, remove that walk’s old cell contributions and apply the new ones exactly once. But the current app treats saved routes as effectively immutable and already has separate sync/export journals; a heatmap should not quietly reuse those journals for a different job. See the project’s [persistence notes](../persistence.md) and [architecture](../architecture.md) for the existing boundaries.

## The privacy edge

Raw routes reveal where you live, work, and return. Aggregation reduces detail, but it does not make personal movement data harmless—especially when the map is public or a cell has only one contributing walk. The safest prototype is local: derive cells on the user’s devices, send no coordinates to a hosted service, and do not publish the result. If sharing ever becomes a goal, decide minimum counts, home-area suppression, and consent before designing the export.

<div class="sources"><h2>Sources</h2><ul><li><a href="https://docs.qgis.org/3.44/en/docs/user_manual/plugins/plugins_heatmap.html">QGIS — Kernel density, radius, and heatmap outputs</a></li><li><a href="https://developer.apple.com/documentation/healthkit/reading-route-data">Apple — Route data batches and accuracy note</a></li><li><a href="https://www.topografix.com/gpx/1/1/">Topografix — Track segment continuity</a></li></ul></div>
