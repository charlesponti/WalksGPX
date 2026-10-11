---
title: iCloud export implementation plan
summary: Defines ten ordered implementation tasks for a reliable GPX folder and agent-readable manifest.
type: proposal
status: proposed
owner: charlesponti
tags: [icloud, implementation-plan, gpx]
related: [icloud-sync-research.md, healthkit-sync.md, persistence.md, development.md]
updated: 2026-10-11
---

# iCloud export implementation plan

## Goal and boundaries

Publish every locally persisted route as an individual GPX file in a
user-visible iCloud Drive folder, with a versioned `manifest.json` that lets
agents discover the routes. The app's Core Data store remains authoritative;
iCloud publication is a retryable mirror. HealthKit sync must continue if
iCloud is unavailable. There is no server, MCP process, Core Data CloudKit
mirroring, or agent-side write access in this change.

Use the existing container `iCloud.io.ponti.walksgpx`; publish its `Documents`
directory as the app-visible folder named `Walks GPX`. Store `manifest.json`
and GPX files directly in that folder. Each GPX filename is
`walk-<workout-uuid>.gpx`.
Manifest schema version 1 contains `schemaVersion`, `generatedAt`, and a
`walks` array. Each entry contains `id`, `filename`, `startDate`, `endDate`,
and `pointCount`. Timestamps are ISO-8601 UTC values. Entries sort by
`startDate`, then UUID. All paths inside the manifest are relative filenames.

## Ordered tasks

### 1. Configure iCloud Documents entitlements and publication metadata

- **Status:** DONE
- Add the existing container to `com.apple.developer.ubiquity-container-identifiers`
  for both app targets while retaining current CloudKit/CloudDocuments values.
- Add `NSUbiquitousContainers` metadata for `iCloud.io.ponti.walksgpx`, display
  name `Walks GPX`, document-scope visibility enabled, and supported folder
  levels `Any` in each app's Info.plist.
- Increment each target's `CFBundleVersion` from `1` to `2`, because changing
  published container metadata requires a higher build number.
- Verify the generated signed entitlements contain the expected container;
  if Apple's developer account does not have this container provisioned for
  the configured team, stop and report that account-side prerequisite.

### 2. Define stable export paths and manifest schema

- **Status:** DONE
- Add shared constants for container ID, visible folder name, manifest name,
  schema version, and deterministic `walk-<UUID>.gpx` filenames.
- Add Codable manifest and entry values with the exact fields in the goal.
- Sort before encoding, and encode timestamps in UTC ISO-8601 format.
- Keep `WalkRoute.filename` unchanged for existing share-sheet behavior.

### 3. Add pure manifest operations and tests

- **Status:** DONE
- Implement deterministic manifest creation from route metadata.
- Verify stable IDs/filenames, sorting, schema version, timestamps, round-trip
  decoding, empty manifests, and duplicate UUID de-duplication in unit tests.
- Keep these pure tests independent of an iCloud account and filesystem.

### 4. Implement a serialized iCloud folder access layer

- **Status:** DONE
- Resolve the ubiquity container at runtime on each access; never persist its
  absolute URL.
- Create the ubiquity container's `Documents` directory as needed and expose a typed unavailable/error
  result when iCloud is not configured or signed in.
- Run coordinated filesystem operations away from the SwiftUI main thread.
- Use `NSFileCoordinator` for iCloud file reads, replacements, and deletions;
  replace the manifest atomically.

### 5. Implement idempotent GPX publication

- **Status:** DONE
- Convert each `WalkRoute` with the existing `GPXExporter` and write it to its
  deterministic UUID filename.
- Write/replace the GPX before adding its entry to the manifest.
- Repeating publication for the same UUID updates the same route file and
  must not duplicate its manifest entry.
- Report local write success separately from iCloud upload completion.

### 6. Implement manifest reconciliation and deletion repair

- **Status:** DONE
- Treat a snapshot from `WalkStore.fetchRoutes()` as authoritative.
- Ensure every snapshot route has a readable GPX file and a matching manifest
  entry; remove manifest entries and generated GPX files for routes absent from
  the snapshot.
- Persist the manifest only after every referenced file exists locally.
- Make retries recover orphan files, missing files, stale entries, and crashes
  between GPX and manifest writes without losing locally saved routes.

### 7. Integrate bounded incremental publication with HealthKit sync

- **Status:** DONE
- Feed successfully persisted routes to the publisher in bounded batches of
  100 so a long historical scan begins producing files before it finishes
  without rewriting the growing manifest excessively.
- Flush the final partial batch and reconcile the complete local snapshot
  before normal sync completion.
- Keep Core Data errors fatal to HealthKit checkpoint advancement; treat iCloud
  errors as non-fatal to local HealthKit sync and retain a retry-needed state.
- On HealthKit deletions, reconcile against the post-delete Core Data snapshot.

### 8. Retry publication from stored data on launch and background refresh

- **Status:** DONE
- On app launch, reconcile already stored walks before or alongside the normal
  HealthKit query, including when HealthKit has not been connected yet.
- Reconcile again during scheduled/manual sync so iCloud outages, app
  termination, or interrupted batches heal without re-reading GPX from a user.
- Do not make iCloud retry depend on requesting HealthKit authorization.

### 9. Expose actionable export status and folder guidance

- **Status:** DONE
- Show whether the folder is unavailable, local writes are pending upload,
  or the latest manifest has been published; include a retry action if needed.
- Never label a file “synced to iCloud” until the platform reports it uploaded.
- Explain where the named folder appears in Files and iCloud Drive on the Mac,
  and that agents should read the manifest and referenced GPX files only.

### 10. Verify, document, and close the implementation

- **Status:** PARTIAL — implementation and automated verification complete; physical iCloud verification pending
- Run the iOS and macOS builds, unit tests, docs validator, and `git diff --check`.
- On the connected iPhone and a Mac using the same Apple Account, verify the
  folder, valid manifest, correct count, deterministic file names, and actual
  cross-device arrival of a route.
- Test iCloud signed-out/unavailable behavior, repeat sync, route deletion,
  interruption/relaunch recovery, and large existing Core Data history.
- Update architecture, persistence, sync, gotchas, and development docs with
  code-verified behavior; replace research caveats that implementation resolves.

## Plan review before implementation

- **Order is dependency-safe:** target entitlements and folder visibility are
  established before runtime lookup; schema tests precede file mutations;
  the publisher exists before HealthKit integration; UI and device verification
  follow a working end-to-end path.
- **Data-loss boundary is explicit:** Core Data remains the source of truth,
  local save failures still prevent the HealthKit anchor from advancing, and
  cloud failures do not block local sync. Launch reconciliation repairs cloud
  copies after anchor advancement or app termination.
- **Conflict risk is bounded:** only the iPhone app writes this folder; Mac
  agents read it. UUID filenames avoid same-minute collisions. Coordinated,
  atomic manifest replacement avoids partial JSON visibility.
- **Scale is addressed:** routes publish in batches of 100 rather than
  rewriting the growing manifest for every workout. A final full snapshot
  reconciliation repairs interrupted batches and propagates deletions.
- **Scope matches the request:** this delivers a user-visible iCloud Drive
  folder and agent-readable manifest without adding a hosted service, MCP
  server, or two-way editing contract.
- **External prerequisites are called out:** physical-device provisioning,
  matching iCloud account/Drive state, and developer-account container
  association cannot be confirmed from source alone; task 10 checks these.

## Definition of done

Tasks 1–9 are implemented. Task 10's automated checks pass, but physical-device
verification remains outstanding because the paired iPhone is currently
unavailable to the development host. The final acceptance criteria are not yet
fully verified: a route saved locally is designed to appear as a UUID-named
GPX and manifest entry after a successful retry, and repeated sync is
idempotent, but actual iCloud Drive delivery and Mac visibility need a
connected iPhone and same-account Mac check.
