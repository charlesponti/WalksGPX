---
title: Walked Here
summary: Follow five short lessons from a satellite fix to a personal map of the streets you have walked.
type: guide
status: active
owner: charlesponti
tags: [geospatial, field-guide, heatmaps]
related: [learn/geopositioning.md, learn/points-to-paths.md, learn/what-heat-means.md, learn/cells-and-distance.md, learn/from-data-to-map.md]
updated: 2026-10-12
---

<p class="opening-mark">A FIELD GUIDE TO YOUR FOOTSTEPS</p>

# Walked Here

## How a walk becomes a map

You leave the door. A receiver listens to satellites. HealthKit keeps a trail of fixes. Those fixes become lines; the lines become measurements; the measurements become a picture of London, walked one street at a time.

This is the computer science behind that transformation. Five compact lessons. No live location data. Read them in order, or jump to the question you have.

<div class="callout"><span class="callout-label">THE BIG IDEA</span><p>A heatmap is not made by pouring every GPS dot onto a map. First decide what the color means. Then choose a spatial unit. Then count or measure each walk without letting sampling noise vote twice.</p></div>

## Five stops

<ol class="lesson-list">
  <li><a href="{{ '/learn/geopositioning/' | relative_url }}"><span><span class="lesson-title">A coordinate is not a place</span><span class="lesson-summary">How satellite timing becomes latitude and longitude—and why the dot is uncertain.</span></span></a></li>
  <li><a href="{{ '/learn/points-to-paths/' | relative_url }}"><span><span class="lesson-title">From points to a path</span><span class="lesson-summary">Sampling, polylines, gaps, interpolation, and the shape between fixes.</span></span></a></li>
  <li><a href="{{ '/learn/what-heat-means/' | relative_url }}"><span><span class="lesson-title">What does “heat” measure?</span><span class="lesson-summary">Coverage, repeat visits, distance, and the misleading glow of raw point counts.</span></span></a></li>
  <li><a href="{{ '/learn/cells-and-distance/' | relative_url }}"><span><span class="lesson-title">Cutting the city into cells</span><span class="lesson-summary">Grids, hexagons, street networks, projections, and route-to-cell accounting.</span></span></a></li>
  <li><a href="{{ '/learn/from-data-to-map/' | relative_url }}"><span><span class="lesson-title">From arithmetic to heatmap</span><span class="lesson-summary">Smoothing, color scales, data structures, performance, and correctness tests.</span></span></a></li>
</ol>

## The question we are trying to answer

“Where have I walked in London?” sounds like one question. It can mean three things: which places you have ever crossed, which places you return to, or how many metres of your walking fall inside each area. Each answer has a different unit and a different aggregation rule. That choice comes before the colors.

The examples use invented routes and schematic diagrams. They do not contain your HealthKit locations or claim to show the real London street network. The guide links to the standards and technical references behind each idea, and marks the difference between established science and a product choice we still need to make.

<div class="sources"><h2>Start with the original sources</h2><p><a href="https://developer.apple.com/documentation/healthkit/reading-route-data">Apple: Reading route data</a> · <a href="https://www.topografix.com/gpx/1/1/">Topografix: GPX 1.1</a> · <a href="https://h3geo.org/docs/">Uber: H3 geospatial index</a></p></div>
