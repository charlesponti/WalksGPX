---
title: Development and verification
summary: Provides project generation, build, test, and device-validation workflows.
type: guide
status: active
owner: charlesponti
tags: [development, xcode, testing]
related: [architecture.md, healthkit-sync.md, macos-workflow.md]
updated: 2026-10-11
---

# Development and verification

## Prerequisites

Install Xcode, XcodeGen, and an Apple Developer team for physical-device
signing. XcodeGen configuration uses Swift 6, iOS 17, macOS 14, and Lottie
4.6.1 (`project.yml:1-14`). Bundle identifiers and entitlements are configured
per target in `project.yml:15-60`.

## Generate and open

```sh
xcodegen generate
open 'WalksGPX.xcodeproj'
```

When changing target settings or source/resource membership, edit `project.yml`
and regenerate the project. The generated `.xcodeproj` is checked in to make
the app directly openable, but project.yml is the declarative source.

## Build and tests

```sh
xcodebuild -project WalksGPX.xcodeproj -scheme 'WalksGPX iOS' -destination 'generic/platform=iOS' build
xcodebuild -project WalksGPX.xcodeproj -scheme 'WalksGPX macOS' -destination 'generic/platform=macOS' build
xcodebuild -project WalksGPX.xcodeproj -scheme 'WalksGPX iOS' -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The exact available simulator name varies by installed Xcode; inspect with
`xcrun simctl list devices available` and substitute an installed device. The
test target currently covers sync-state encoding/compatibility and progress
bounds (`Tests/SyncStateStoreTests.swift:5-104`), not all application behavior
or “100% coverage.” HealthKit authorization and actual workout data need
physical-device checks.

## Device smoke test

Select the iOS scheme and connected iPhone, set the signing team, build and
run. Verify the app installs with a valid executable, requests Health access,
shows progress, and saves route walks. Check a known long GPS-recorded walk
with a preview and export a GPX file, then inspect its track points. For a
long initial history, keep the app foregrounded while it scans; background
refresh time is not guaranteed.

Do not commit `DerivedData`, `xcuserdata`, signing identities, provisioning
profiles, or environment secrets. `.gitignore` covers common local artifacts;
the project file, schemes, package resolution, and Lottie JSON are intentional
tracked inputs.
