---
title: What heat means
summary: Choose whether a walking map represents coverage, repeat walks, distance, time, or raw samples.
type: guide
status: active
owner: charlesponti
tags: [heatmaps, aggregation, metrics]
related: [../index.md, points-to-paths.md, cells-and-distance.md, from-data-to-map.md]
updated: 2026-10-12
---

# What does “heat” measure?

Color is not a metric. A red area only means “more” after we say more of what.

## Four valid maps, four different questions

| Map | Question | Contribution from one walk |
| --- | --- | --- |
| **Coverage** | Have I walked here at least once? | Mark each crossed cell as visited. |
| **Walk frequency** | How many separate walks came through? | Add one per walk per cell, even if that walk has many fixes there. |
| **Distance** | How many metres of recorded path lie here? | Split each route segment’s length across the cells it crosses. |
| **Time** | How much workout time happened here? | Allocate elapsed time along a path, with assumptions about speed between fixes. |

These can share a map style, but they should not share a label. “Visits” must not be shown as “distance.” “Coverage” is not a measure of how often you return.

## Why exact-point deduplication fails

Two GPS readings from the same pavement may differ by several metres. Exact coordinate equality is rare; rounding coordinates to a fixed number of decimal places hides that problem without giving a stable physical cell size. Decimal degrees do not represent a constant metre width everywhere.

The deeper issue is that point counts depend on sampling. A route with a long pause or denser recording can contribute more dots even though you did not cover more ground. Kernel-density tools built from points do exactly what they are asked to do: estimate the density of points. If the points are not an unbiased representation of the quantity you care about, the smooth picture can still be misleading. [QGIS describes heatmaps as point-density estimation and makes the kernel radius a key parameter.](https://docs.qgis.org/3.44/en/docs/user_manual/plugins/plugins_heatmap.html)

## A small derivation

Let `R` be your set of walks and `C` the set of spatial cells. Let `L(r, c)` be the length of walk `r` that falls inside cell `c`.

<div class="equation" role="math" aria-label="distance in a cell equals the sum of each walk's route length within the cell">distance(c) = Σ<sub>r ∈ R</sub> L(r, c)<small>The sum runs over walks. GPS fixes are used to estimate each route; they are not the quantity being summed.</small></div>

Walk frequency is a different sum:

<div class="equation" role="math" aria-label="walk count in a cell equals the number of distinct walks that crossed that cell">walks(c) = Σ<sub>r ∈ R</sub> 𝟙[L(r, c) &gt; 0]<small>𝟙 is one when the walk crossed the cell, otherwise zero. One walk cannot count twice in the same cell.</small></div>

The set indicator is the important deduplication rule. Deduplicate **by walk identity and cell**, not by exact latitude/longitude. A walk crossing the same cell, pausing there, and generating fifty additional fixes still counts as one walk in that cell.

## Which one sounds like your map?

“All the areas I’ve walked” is closest to **coverage**. It gives every place a yes/no answer. It is easy to explain and does not let a route with many sampled fixes dominate. But once every cell has been colored, walking the same street again adds nothing.

“Where do I walk most?” is **walk frequency**. It captures habits: a corridor walked on many different days glows more than a one-off detour. It counts separate walks, not how long each one lasted.

“How much of London have I walked?” is most naturally **distance**. It adds metres inside each area. It distinguishes a short crossing from a long wander, but depends more on route reconstruction and coordinate accuracy.

My recommendation for exploration is not to collapse these questions. Start with coverage as the outline of the territory you know. Offer walk frequency and distance as explicitly named lenses. That lets you discover which picture feels meaningful before choosing a single default.

## One walk, one contribution ledger

An archive may be reprocessed after a bug fix or a new cell size. If each retry blindly adds totals, the same walk counts twice. Treat the walk UUID as an idempotency key: either recompute the full derived layer from source routes, or store a per-walk contribution set that can be replaced atomically. For a personal archive of a few thousand walks, full recomputation may be simpler and safer at first; incremental updates can come later if measurement shows the need.

The derived totals are not the source of truth. The route is. That gives us a recovery path if we change the heat metric, grid, projection, or accuracy rules.

<div class="sources"><h2>Sources</h2><ul><li><a href="https://docs.qgis.org/3.44/en/docs/user_manual/plugins/plugins_heatmap.html">QGIS — Kernel-density heatmaps and radius</a></li><li><a href="https://pmc.ncbi.nlm.nih.gov/articles/PMC4786863/">Brodie et al. — GPS sampling error can inflate measured distance</a></li><li><a href="https://developer.apple.com/documentation/healthkit/reading-route-data">Apple — HealthKit route data and smoothing note</a></li></ul></div>
