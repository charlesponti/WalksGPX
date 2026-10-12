---
title: Geopositioning
summary: Understand how satellite timing becomes coordinates and why every recorded point carries uncertainty.
type: guide
status: active
owner: charlesponti
tags: [gps, coordinates, uncertainty]
related: [../index.md, points-to-paths.md, cells-and-distance.md]
updated: 2026-10-12
---

# A coordinate is not a place

The blue dot on a map looks certain. It is not. It is the receiver’s best estimate, made from radio signals, a model of the Earth, and the geometry of the satellites it can hear.

## The clock becomes a ruler

GPS satellites broadcast their positions and very precise time. A phone compares the time a signal was sent with the time it arrived. Radio travels at a known speed, so elapsed time gives an estimated distance: `distance ≈ speed of light × travel time`.

Each satellite gives the receiver a sphere of possible locations. The receiver solves for the point where the spheres meet. In three dimensions it must also solve for an error in its own clock, so it needs signals from at least four satellites. The measurements are not perfect distances; the receiver solves a noisy system of equations and finds the position that best fits them. [GPS.gov explains the signal and trilateration model.](https://www.gps.gov/gps)

<div class="diagram" role="img" aria-label="GPS signals lead to estimated distances, then a position solution and coordinate pair">
  <div class="step"><b>01</b><span>Satellite sends position + time</span></div><div class="arrow">↓</div>
  <div class="step"><b>02</b><span>Phone measures signal travel time</span></div><div class="arrow">↓</div>
  <div class="step"><b>03</b><span>Geometry solves position + clock error</span></div><div class="arrow">↓</div>
  <div class="step"><b>04</b><span>Reference frame gives latitude + longitude</span></div>
  <p class="fine">A solution is an estimate with an uncertainty—not a pin driven into the Earth.</p>
</div>

## Latitude and longitude are angles

Latitude measures north–south angle from the equator. Longitude measures east–west angle from a reference meridian. A pair such as `51.5072°, −0.1276°` identifies a location only when we also know the reference frame—the model that says how those numbers relate to the Earth.

GPX uses the WGS 84 datum and stores coordinates as latitude and longitude. These are angular measurements, not metres. One degree of longitude spans less ground as you move toward the poles; you cannot safely subtract two longitude values and call the result a walking distance. A coordinate reference system (CRS) tells software how to interpret and transform coordinates. [The GPX 1.1 schema states its WGS 84 convention.](https://www.topografix.com/gpx/1/1/) [The Open Geospatial Consortium explains the difference between geographic and projected coordinate systems.](https://docs.ogc.org/as/18-005r4/18-005r4.html)

## The point has a fuzzy edge

Buildings block signals. Glass and stone reflect them. Trees, bridges, atmospheric delays, satellite geometry, and the receiver all matter. GPS.gov says smartphone accuracy is typically within about 4.9 metres under open sky, and gets worse near obstructions. Apple’s HealthKit route guidance warns that route locations may need smoothing and describes their accuracy as within 50 metres. Those figures describe different contexts; neither promises that a particular point is correct to that radius on a particular street. [GPS accuracy](https://www.gps.gov/gps-accuracy) · [Apple route data](https://developer.apple.com/documentation/healthkit/reading-route-data)

Core Location’s `horizontalAccuracy` is itself an uncertainty radius around the estimated coordinate. It is not a guarantee, a street-match score, or a direction to move the point. A future analysis can use accuracy to flag or down-weight uncertain fixes—but only if that value survives ingestion and storage.

<div class="callout"><span class="callout-label">WALKSGPX TODAY</span><p>The current <code>RouteLocation</code> stores latitude, longitude, optional elevation, and timestamp. It does not retain horizontal accuracy (<code>Shared/WalkRoute.swift:32–40</code>). HealthKit supplies <code>CLLocation</code> objects in batches (<code>iOS/HealthKitService.swift:46</code> is where the current model is made). If confidence-aware filtering becomes important, the model would need to preserve accuracy first.</p></div>

## Why this matters for a heatmap

Imagine a true footpath as a thin line and each GPS fix as a fuzzy circle around it. The line is not known exactly. If the heat grid is finer than the uncertainty, tiny shifts can move the same walk between neighboring cells. A 5-metre cell does not become accurate just because the computer draws it sharply.

This gives us a useful rule: choose a spatial resolution that matches the data’s uncertainty and the question. A citywide pattern may be convincing at neighbourhood scale even when exact curbside placement is not. A street-by-street claim needs stronger evidence than a warm-colored square.

<div class="sources"><h2>Sources</h2><ul><li><a href="https://www.gps.gov/gps">GPS.gov — GPS system and positioning</a></li><li><a href="https://www.gps.gov/gps-accuracy">GPS.gov — GPS accuracy and error sources</a></li><li><a href="https://developer.apple.com/documentation/healthkit/reading-route-data">Apple — Reading route data</a></li><li><a href="https://developer.apple.com/documentation/corelocation/cllocation/horizontalaccuracy">Apple — <code>horizontalAccuracy</code></a></li><li><a href="https://www.topografix.com/gpx/1/1/">Topografix — GPX 1.1 schema</a></li></ul></div>
