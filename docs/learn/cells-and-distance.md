---
title: Cells and distance
summary: Compare spatial grids and learn how to distribute a walk across cells without counting GPS samples.
type: guide
status: active
owner: charlesponti
tags: [spatial-indexing, grids, distance]
related: [../index.md, geopositioning.md, points-to-paths.md, what-heat-means.md]
updated: 2026-10-12
---

# Cutting the city into cells

Computers need a finite set of places to count. A heatmap turns a continuous city into bins: each point or line segment is assigned to one or more spatial cells, and each cell stores a number.

## Pick the shape to match the question

<div class="table-wrap"><table><thead><tr><th>Representation</th><th>What it buys</th><th>What it costs</th></tr></thead><tbody>
<tr><td><strong>Square raster</strong></td><td>Simple indexing; easy to render as pixels; clean line–cell intersection math.</td><td>Grid direction can make diagonal routes look different; cells are awkward near the edge of a chosen extent.</td></tr>
<tr><td><strong>Hexagon grid</strong></td><td>Neighbors are more uniform; cells have a recognizable identity at multiple scales.</td><td>Cells are not equal-area everywhere; line traversal and hierarchy have special cases.</td></tr>
<tr><td><strong>Street segments</strong></td><td>The result answers “which streets did I walk?” directly.</td><td>Needs a street/footpath network and map matching. A wrong match can place a route on the wrong side of a block.</td></tr>
</tbody></table></div>

H3 is one well-known hierarchical hexagonal index. Its `latLngToCell` operation assigns a coordinate to a cell at a chosen resolution. A coarser resolution groups more ground into each cell; a finer one creates more precise-looking—but not necessarily more accurate—detail. H3’s documentation also warns that hierarchical parent/child containment is approximate geometrically, even though cell IDs are logically hierarchical. [H3 indexing](https://h3geo.org/docs/api/indexing/) · [H3 resolution statistics](https://h3geo.org/docs/core-library/restable/).

For this project, a square grid is the easiest first algorithm to understand and test. H3 is a credible next experiment if hexagonal regions make the map easier to read. Street matching is a separate, more ambitious mode—not a prerequisite for a useful area heatmap.

## Degrees are not metres

The raw route stores latitude and longitude. To measure distance in a grid, convert coordinates into a local projected CRS whose axes have metre units. For London, British National Grid (EPSG:27700) is a natural candidate. A projected CRS maps the curved Earth onto a plane; every projection distorts something, so use one suited to the region and measure. The OGC catalogue describes British National Grid as EPSG:27700, and PostGIS documents that geometry length uses the units of its spatial reference system. [OGC CRS reference](https://docs.ogc.org/cs/21-069r2/21-069r2.html) · [PostGIS `ST_Length`](https://postgis.net/docs/manual-3.7/en/ST_Length.html).

Do not merely relabel longitude/latitude values as metres. A coordinate transform computes new numbers; changing the CRS label alone does not. This is one of the most common ways to get a distance that looks plausible but is wrong.

## Put a line through the grid

Assigning just the recorded fixes to cells can miss cells between them. If two samples are far apart, they may be several blocks apart. For a distance map, the route segment between them must contribute to every cell it crosses.

For a square grid, a line-traversal algorithm walks from boundary to boundary and lists the crossed cells. Then clip the segment to each cell boundary and add the clipped length. Think of laying a piece of string across graph paper: each square receives only the length of string inside it.

```text
for each walk:
    visitedCells = empty set
    for each valid adjacent fix pair in a continuous segment:
        line = project pair into metre coordinates
        for each grid cell crossed by line:
            piece = length(line inside cell)
            distance[cell] += piece
            visitedCells.add(cell)
    for each cell in visitedCells:
        walkCount[cell] += 1
```

The `visitedCells` set is reset for each walk. That makes walk frequency “one walk, one vote per cell.” The distance accumulator receives metres and can receive many pieces from one route.

## Resolution is a question, not a styling choice

A 20-metre grid can show more detail than a 200-metre grid, but also amplifies GPS wobble and map-matching errors. A 200-metre grid can reveal broad patterns while hiding which parallel street you used. A good resolution should be tested against location uncertainty, route spacing, London’s block size, and the decision the map should help you make.

Use nested scale as an experiment: show the same archive at neighbourhood, district, and city scales. If a pattern disappears or reverses when the cell size changes slightly, the conclusion may be an artifact of the grid. This is the modifiable areal unit problem in miniature: changing the boundaries can change the statistics.

## A conservation check

After distributing line length, sum the cell contributions. It should be close to the length of the accepted route segments, allowing for numerical tolerance and for portions deliberately rejected as gaps or outliers. If a route is 5 km long and the grid ledger says 500 m or 50 km, the bug is in geometry or units—not in the color palette.

For walk frequency, every route-cell pair should occur once. For coverage, every cell’s value is simply whether at least one route crossed it. These invariants make the algorithm testable before any map is drawn.

<div class="sources"><h2>Sources</h2><ul><li><a href="https://h3geo.org/docs/api/indexing/">H3 — Coordinate-to-cell indexing</a></li><li><a href="https://h3geo.org/docs/highlights/indexing/">H3 — Hierarchical cells and approximate containment</a></li><li><a href="https://h3geo.org/docs/core-library/restable/">H3 — Resolution and cell-size statistics</a></li><li><a href="https://docs.ogc.org/cs/21-069r2/21-069r2.html">OGC — British National Grid, EPSG:27700</a></li><li><a href="https://postgis.net/docs/manual-3.7/en/ST_Length.html">PostGIS — Length units and geodesic length</a></li></ul></div>
