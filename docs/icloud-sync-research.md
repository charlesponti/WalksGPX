---
title: iCloud Drive export research
summary: Records Apple platform requirements and reliability constraints for publishing GPX files and a manifest.
type: reference
status: active
owner: charlesponti
tags: [icloud, gpx, research]
related: [icloud-sync-plan.md, healthkit-sync.md, persistence.md, development.md]
updated: 2026-10-11
---

# iCloud Drive export research

## Current project facts

At research time, both targets declared `iCloud.io.ponti.walksgpx` and
`CloudDocuments` but did not yet declare
`com.apple.developer.ubiquity-container-identifiers`. The implementation adds
that entitlement, visible-container metadata, and the file publisher. The
local Core Data store remains the primary copy on each device
(`Shared/WalkStore.swift:54-65`).

## Platform requirements

Use iCloud Documents for the route files and JSON manifest. Apple distinguishes
iCloud Documents from CloudKit: the former stores files in a ubiquity
container; the latter stores structured records in CloudKit. Enabling an iCloud
service requires its corresponding Xcode capability and entitlements. The
iCloud Documents configuration includes the selected container in
`com.apple.developer.ubiquity-container-identifiers`; code resolves the
container at runtime with
[`FileManager.url(forUbiquityContainerIdentifier:)`](https://developer.apple.com/documentation/foundation/filemanager/url%28forubiquitycontaineridentifier%3A%29).
Apple notes that this lookup can return `nil` when the account, device, or
container is unavailable. Treat that as a retryable export condition and keep
local routes usable. See [Configuring iCloud services](https://developer.apple.com/documentation/Xcode/configuring-icloud-services?changes=_11%2C_11)
and the [container URL API](https://developer.apple.com/documentation/foundation/filemanager/url%28forubiquitycontaineridentifier%3A%29?changes=latest_b__9__1__1_1&language=objc).

Files inside an app's ubiquity container can sync across that user's iCloud
devices. Publishing container metadata in `Info.plist` with
`NSUbiquitousContainers` exposes a named folder in iCloud Drive; Apple's
document synchronization guide also requires a higher build version when
container metadata changes. The `Documents` directory is user-visible, so
route files there are intentionally accessible through Files/Finder and other
authorized local apps. “Public” in the container metadata means exposed as
user documents, not anonymously published to the internet. See [Synchronizing
documents in iCloud](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment?changes=_8)
and [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html).

Resolve the ubiquity container at runtime rather than persisting its absolute
URL. Apple describes the container as a local representation of the user's
cloud storage; the available location is not a stable app-owned absolute path.
Use the app's `Documents` directory as the export folder; container metadata
gives it the visible name `Walks GPX`. This avoids a redundant `Walks GPX/Walks
GPX` directory structure. Use deterministic filenames derived from HealthKit
workout UUIDs. See [iCloud file management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html).

## File integrity and manifest design

Apple's file coordination API coordinates reads and writes among processes
and file presenters. Perform iCloud-folder writes and reads through
`NSFileCoordinator`; write the route file before publishing a manifest entry
that points to it. Use atomic replacement for the manifest so readers do not
observe partially serialized JSON. Keep a single writer (the iPhone app) for
this export folder; the Mac and agents are readers. See [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator?changes=_7)
and [coordinated read/write](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate%28readingitemat%3Aoptions%3Awritingitemat%3Aoptions%3Aerror%3Abyaccessor%3A%29).

Use a versioned JSON manifest with a stable workout UUID, relative GPX
filename, start/end timestamps, and point count per entry. Sort entries by
start date then UUID for deterministic serialization. Do not store absolute
container paths in the manifest. Rewrite the index after bounded batches, not
after each workout; large histories would otherwise repeatedly upload the
growing whole JSON file. A GPX file written without a manifest entry is
recoverable: the local Core Data store remains authoritative and a later
reconciliation can republish the file and index.

Update GPX files by deterministic UUID, not only start-time filenames, because
two walks can begin within the same filename minute. Reconcile manifest
entries against locally persisted routes so deleted HealthKit workouts remove
their generated GPX and stale index entries. Make reconciliation idempotent;
an app crash between the file write and manifest replacement must be repaired
on a subsequent pass.

## Delivery timing and failure boundaries

iCloud file synchronization is system-managed and asynchronous. Resource
values expose whether an item is uploaded, uploading, downloaded, or has an
upload error, but writing a file does not mean it is already available on the
Mac. See [`URLResourceValues.ubiquitousItemDownloadingStatus`](https://developer.apple.com/documentation/foundation/urlresourcevalues/ubiquitousitemdownloadingstatus?changes=_1%2C_1%2C_1%2C_1)
and [`FileManager.startDownloadingUbiquitousItem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem%28at%3A%29).

Do not make HealthKit anchor advancement depend on iCloud availability. The
local Core Data route save and HealthKit checkpoint are the local sync's
durability boundary (`iOS/HealthKitService.swift:137-165`). A cloud-container
or file-coordination error should leave local sync usable, surface an export
status, and trigger a later reconciliation from Core Data. Existing background
refresh is best effort; `earliestBeginDate` is only a not-before time, not a
run guarantee ([Apple background-task guide](https://developer.apple.com/documentation/UIKit/using-background-tasks-to-update-your-app?changes=_1),
[`BGTaskRequest.earliestBeginDate`](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate?changes=_3)).

## Device verification requirements

The iPhone and Mac must use the same Apple Account with iCloud Drive enabled,
and the signed app entitlements must include the selected ubiquity container.
Test on physical devices: simulator state does not demonstrate iCloud Drive
account setup, upload completion, Files visibility, or cross-device delivery.
Check both local file and iCloud upload resource status; do not report an
export as “available on Mac” merely because the local write succeeded.
