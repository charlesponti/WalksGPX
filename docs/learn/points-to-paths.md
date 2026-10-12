---
title: From points to paths
summary: Learn how ordered GPS fixes become a route and where interpolation can invent geography.
type: guide
status: active
owner: charlesponti
tags: [gps, trajectories, gpx]
related: [../index.md, geopositioning.md, what-heat-means.md, cells-and-distance.md]
updated: 2026-10-12
---

# From points to a path

A GPS recorder does not watch your shoes touch every paving stone. It records samples: an estimated position at a time. A route is the computer’s reconstruction from those samples.

## A track is an ordered sequence

Represent a fix as a tuple:

```text
pᵢ = (latitudeᵢ, longitudeᵢ, timestampᵢ, accuracyᵢ?)
```

Sort fixes by time. Draw a straight segment from each fix to the next. The ordered segments form a polyline. It is a useful approximation of a walk, not a transcript of every turn your feet made.

```text
fix 1 ───── fix 2 ───── fix 3 ───── fix 4
  •            •            •            •
       inferred       inferred
        segment        segment
```

GPX calls an ordered path a track. A track can contain several track segments. The GPX standard uses a new segment when the track is not continuous—for example, when GPS reception was lost or the receiver was turned off. Joining those segments with a straight line would invent a route through a place where no path was recorded. [GPX 1.1 track and segment definitions](https://www.topografix.com/gpx/1/1/).

Apple HealthKit may return one workout route in multiple asynchronous batches. The batches are a transport detail; they must be assembled before the route is analyzed. Apple also notes that route samples may be updated after their initial creation, so the apparent point sequence is data to retrieve and validate, not a permanent immutable fact. [Apple: Reading route data](https://developer.apple.com/documentation/healthkit/reading-route-data).

## Sampling is not walking

Suppose a recorder saves one point every few seconds. If you stop for a minute, it may save many points in the same small area. If you walk briskly along a straight road, it may save fewer points per metre. Count the fixes and you count the recorder’s sampling behavior as much as your movement.

The spacing between fixes also changes what we can infer. When two nearby points are recorded a few seconds apart, a straight connection is often a reasonable approximation. When the next point is far away in time or space, the straight line may cut across a park, a block, or a river bend. It is not evidence that you took that exact path.

There are two distinct problems:

1. **Sampling gaps:** no observation exists for part of the walk. Interpolation draws a plausible connector, but cannot recover an unknown turn.
2. **Measurement noise:** observed coordinates wobble around the true path. Smoothing may make a line look calmer, but an aggressive smoother can erase real corners or move a route off the street.

GPS measurement error can also make the sum of tiny point-to-point distances too long. High-frequency jitter adds little zigzags; each zigzag contributes positive length. A research study demonstrates this systematic distance inflation and explains why autocorrelated location error matters. [“Why GPS makes distances bigger than they are”](https://pmc.ncbi.nlm.nih.gov/articles/PMC4786863/).

## Three kinds of “fixing” a route

**Filtering** removes points that are invalid or implausible—for example, non-finite coordinates or a jump that would require an impossible speed. **Smoothing** changes the path to reduce noise. **Map matching** associates the uncertain path with a street or footpath network. These are not synonyms, and none is automatically correct.

Map matching introduces another model: the street network. A matcher must decide which candidate roads a point could belong to, then use sequence and connectivity to pick a likely path. This can help when GPS wanders beside a street, but it can confidently choose the wrong parallel road, courtyard, or footpath. It should be treated as an estimate with a method and a confidence—not as raw truth.

## A route segment is the basic unit of distance

Given two fixes `A` and `B`, the simplest route approximation is the straight segment `AB`. Its length depends on the coordinate system. Latitude/longitude are angular coordinates, so for precise local length we first transform to a suitable projected coordinate system with metre units, or compute geodesic distance on the Earth’s surface. The choice matters more over a large area; for one London walk, a suitable local projection is practical.

The segment’s straight-line length is still a chord approximation to the path actually walked. The timestamp gap, accuracy radius, speed, and context tell us how much confidence to place in it. If there is a long gap, the safest result may be to leave the interval unknown rather than paint an invented bridge across it.

<div class="callout"><span class="callout-label">WALKSGPX TODAY</span><p>The stored model is a flat ordered array of coordinates and timestamps (<code>Shared/WalkRoute.swift:3–7, 32–40</code>). The current GPX exporter writes those locations into one <code>trkseg</code> (<code>Shared/GPXExporter.swift:8–22</code>). A heat-analysis pipeline should explicitly decide how to detect discontinuities before treating every neighboring pair as a real segment.</p></div>

## The first clean model

For each continuous track segment, process adjacent pairs. Validate both endpoints, calculate elapsed time and distance, reject or flag implausible jumps, then pass the remaining line segment to the spatial aggregation step. Do not connect across a known segment break. Keep the original fixes as the source and treat smoothed or map-matched geometry as derived data that can be recomputed.

That separation is valuable: measurement, reconstruction, and visualization are different layers. If a heatmap looks wrong, we can ask whether the points were inaccurate, the line was reconstructed badly, the metric was ill-chosen, or the color scale exaggerated it.

<div class="sources"><h2>Sources</h2><ul><li><a href="https://developer.apple.com/documentation/healthkit/reading-route-data">Apple — HealthKit route batches and route updates</a></li><li><a href="https://www.topografix.com/gpx/1/1/">Topografix — GPX tracks and discontinuous track segments</a></li><li><a href="https://pmc.ncbi.nlm.nih.gov/articles/PMC4786863/">Brodie et al. — GPS measurement error and distance inflation</a></li><li><a href="https://docs.ogc.org/as/18-005r4/18-005r4.html">OGC — Coordinate reference systems</a></li></ul></div>
