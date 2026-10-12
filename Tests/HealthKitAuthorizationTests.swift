import HealthKit
import CoreLocation
import XCTest
@testable import WalksGPX_iOS

@MainActor
final class HealthKitAuthorizationTests: XCTestCase {
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HealthKitAuthorizationTests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        try await super.tearDown()
    }
    func testRequestAccessReportsUnavailableHealthDataWithoutRequestingAuthorization() async {
        let service = HealthKitService(
            healthDataAvailable: { false },
            requestAuthorization: { XCTFail("Authorization should not be requested") }
        )

        await service.requestAccessAndLoad()

        XCTAssertEqual(service.errorMessage, "Health data isn’t available on this device.")
        XCTAssertFalse(service.hasConnected)
    }

    func testRequestAccessDisplaysAuthorizationFailure() async {
        let service = HealthKitService(
            healthDataAvailable: { true },
            requestAuthorization: { throw AuthorizationError.denied }
        )

        await service.requestAccessAndLoad()

        XCTAssertEqual(service.errorMessage, AuthorizationError.denied.localizedDescription)
        XCTAssertFalse(service.hasConnected)
    }

    func testRequestAccessMarksConnectionAndRunsInitialSync() async {
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        let service = HealthKitService(
            syncState: state,
            healthDataAvailable: { true },
            requestAuthorization: {},
            queryOverrides: queries(
                changes: (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 11)),
                route: { _ in nil }
            )
        )

        await service.requestAccessAndLoad()

        XCTAssertTrue(service.hasConnected)
        XCTAssertTrue(state.hasConnected)
        XCTAssertEqual(state.anchor, HKQueryAnchor(fromValue: 11))
        XCTAssertNil(service.errorMessage)
    }

    @available(iOS, deprecated: 17.0)
    func testIncrementalSyncSavesRouteAndAdvancesAnchor() async throws {
        let workout = makeWorkout()
        let route = makeRoute(id: workout.uuid)
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        let service = HealthKitService(syncState: state, queryOverrides: queries(
            changes: (added: [workout], deleted: [], anchor: HKQueryAnchor(fromValue: 1)),
            route: { _ in route }
        ))
        defer {
            try? WalkStore.shared.delete(ids: [route.id])
        }

        let synced = await service.syncIncrementally()
        let persistedRoute = try await WalkStore.shared.fetchRoute(id: route.id)
        XCTAssertTrue(synced)
        XCTAssertEqual(persistedRoute, route)
        XCTAssertTrue(state.pendingRouteIDs.isEmpty)
        XCTAssertEqual(state.anchor, HKQueryAnchor(fromValue: 1))
    }

    @available(iOS, deprecated: 17.0)
    func testNewRouteIsPublishedFromDurableQueueAndQueueIsAcknowledged() async throws {
        let workout = makeWorkout()
        let route = makeRoute(id: workout.uuid)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalksGPXServiceExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? WalkStore.shared.delete(ids: [route.id])
            try? FileManager.default.removeItem(at: folder)
        }

        let state = SyncStateStore(defaults: makeDefaults())
        state.markFullHistoryBackfillComplete()
        state.markWorkoutMetadataBackfillComplete()
        state.markInitialICloudReconciliationComplete()
        let publisher = ICloudGPXPublisher(exportFolderProvider: { folder })
        let service = HealthKitService(
            syncState: state,
            queryOverrides: queries(
                changes: (added: [workout], deleted: [], anchor: HKQueryAnchor(fromValue: 8)),
                route: { _ in route }
            ),
            iCloudPublisher: publisher
        )

        let succeeded = await service.syncIncrementally()

        XCTAssertTrue(succeeded)
        XCTAssertTrue(state.pendingICloudRouteIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("walk-\(route.id.uuidString.lowercased()).gpx").path))
        let manifestData = try Data(contentsOf: folder.appendingPathComponent(ICloudExportConfiguration.manifestFilename))
        XCTAssertEqual(try ICloudExportManifest.decode(manifestData).walks.map(\.id), [route.id])
    }

    @available(iOS, deprecated: 17.0)
    func testCompletedRouteLookupWithNoRouteIsNotRetriedOnNextLaunch() async throws {
        let workout = makeWorkout()
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        state.save(anchor: HKQueryAnchor(fromValue: 1), pendingRouteIDs: [workout.uuid])
        var pendingWorkoutQueries = 0
        var routeQueries = 0
        let service = HealthKitService(syncState: state, queryOverrides: HealthKitQueryOverrides(
            workoutChanges: { (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 2)) },
            pendingWorkouts: {
                pendingWorkoutQueries += 1
                return [workout]
            },
            allWalkingWorkouts: { [] },
            route: { _ in
                routeQueries += 1
                return nil
            }
        ))
        defer { try? WalkStore.shared.delete(ids: [workout.uuid]) }
        let synced = await service.syncIncrementally()

        XCTAssertTrue(synced)
        XCTAssertEqual(service.pendingRouteCount, 0)
        XCTAssertTrue(state.pendingRouteIDs.isEmpty)
        let page = try await WalkStore.shared.fetchRouteSummaryPage(
            limit: 10,
            filter: WalkSearchFilter(startDate: workout.startDate, endDate: workout.endDate.addingTimeInterval(1))
        )
        XCTAssertEqual(page.summaries.first?.id, workout.uuid)
        XCTAssertEqual(page.summaries.first?.hasGPSRoute, false)

        let relaunchedService = HealthKitService(syncState: SyncStateStore(defaults: defaults), queryOverrides: HealthKitQueryOverrides(
            workoutChanges: { (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 3)) },
            pendingWorkouts: {
                pendingWorkoutQueries += 1
                return [workout]
            },
            allWalkingWorkouts: { [] },
            route: { _ in
                routeQueries += 1
                return nil
            }
        ))
        let relaunchedSync = await relaunchedService.syncIncrementally()
        XCTAssertTrue(relaunchedSync)
        XCTAssertEqual(pendingWorkoutQueries, 1, "No pending HealthKit query should run after a completed empty route lookup")
        XCTAssertEqual(routeQueries, 1, "A stable no-route workout should not be queried on every launch")
    }

    @available(iOS, deprecated: 17.0)
    func testExplicitHistoryImportUpgradesPreviouslyUnavailableRouteWithoutDuplicatingWalk() async throws {
        let workout = makeWorkout()
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let state = SyncStateStore(defaults: makeDefaults())
        state.save(anchor: HKQueryAnchor(fromValue: 3))
        state.markFullHistoryBackfillComplete()
        state.markWorkoutMetadataBackfillComplete()

        let firstService = HealthKitService(
            syncState: state,
            queryOverrides: queries(
                changes: (added: [workout], deleted: [], anchor: HKQueryAnchor(fromValue: 4)),
                route: { _ in nil }
            ),
            iCloudReconciliationOverride: {},
            walkStore: store
        )
        let firstSync = await firstService.syncIncrementally()
        let firstWalkCount = try await store.fetchWalkCount()
        let firstRouteCount = try await store.fetchWalkCount(requiringGPSRoute: true)
        XCTAssertTrue(firstSync)
        XCTAssertEqual(firstWalkCount, 1)
        XCTAssertEqual(firstRouteCount, 0)

        let route = makeRoute(id: workout.uuid)
        let secondState = SyncStateStore(defaults: makeDefaults())
        secondState.save(anchor: HKQueryAnchor(fromValue: 4))
        secondState.markFullHistoryBackfillComplete()
        secondState.markWorkoutMetadataBackfillComplete()
        let secondService = HealthKitService(
            syncState: secondState,
            queryOverrides: queries(
                changes: (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 5)),
                historical: [workout],
                route: { _ in route }
            ),
            iCloudReconciliationOverride: {},
            walkStore: store
        )

        await secondService.importFullHistory()

        let upgradedWalkCount = try await store.fetchWalkCount()
        let upgradedRouteCount = try await store.fetchWalkCount(requiringGPSRoute: true)
        let upgradedRoute = try await store.fetchRoute(id: workout.uuid)
        XCTAssertEqual(upgradedWalkCount, 1, "Route arrival upgrades the existing workout UUID, it does not create another walk")
        XCTAssertEqual(upgradedRouteCount, 1)
        XCTAssertEqual(upgradedRoute, route)
        XCTAssertEqual(secondState.anchor, HKQueryAnchor(fromValue: 5))
    }

    @available(iOS, deprecated: 17.0)
    func testHealthKitDeletionRemovesWalkAndJournalsCloudDeletion() async throws {
        let workout = makeWorkout()
        let route = makeRoute(id: workout.uuid)
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        try await store.saveRoutes([route])
        let state = SyncStateStore(defaults: makeDefaults())
        state.save(anchor: HKQueryAnchor(fromValue: 8))
        state.markFullHistoryBackfillComplete()
        state.markWorkoutMetadataBackfillComplete()
        let service = HealthKitService(
            syncState: state,
            queryOverrides: queries(
                changes: (added: [], deleted: [workout.uuid], anchor: HKQueryAnchor(fromValue: 9)),
                route: { _ in XCTFail("A deleted workout must never trigger route lookup"); return nil }
            ),
            iCloudReconciliationOverride: {},
            walkStore: store
        )

        let succeeded = await service.syncIncrementally()
        let walkCount = try await store.fetchWalkCount()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(walkCount, 0)
        XCTAssertTrue(state.pendingICloudDeletionIDs.contains(workout.uuid))
        XCTAssertEqual(state.anchor, HKQueryAnchor(fromValue: 9))
    }

    @available(iOS, deprecated: 17.0)
    func testFailedICloudWriteKeepsDurableRouteJournalForRetry() async throws {
        let route = makeRoute(id: UUID())
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        try await store.saveRoutes([route])
        let state = SyncStateStore(defaults: makeDefaults())
        state.save(anchor: HKQueryAnchor(fromValue: 1))
        state.markFullHistoryBackfillComplete()
        state.markWorkoutMetadataBackfillComplete()
        state.markInitialICloudReconciliationComplete()
        state.enqueueICloudRouteIDs([route.id])
        let failingPublisher = ICloudGPXPublisher(exportFolderProvider: { throw QueryError.failed })
        let failedService = HealthKitService(
            syncState: state,
            queryOverrides: queries(changes: (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 2)), route: { _ in nil }),
            iCloudPublisher: failingPublisher,
            walkStore: store
        )

        let healthKitSucceeded = await failedService.syncIncrementally()
        XCTAssertTrue(healthKitSucceeded, "A Drive failure must not roll back a committed HealthKit anchor")
        XCTAssertTrue(state.pendingICloudRouteIDs.contains(route.id))
        XCTAssertTrue(failedService.iCloudExportMessage?.contains("needs a retry") == true)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalksGPXRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let retryService = HealthKitService(
            syncState: state,
            iCloudPublisher: ICloudGPXPublisher(exportFolderProvider: { folder }),
            walkStore: store
        )
        await retryService.retryICloudExport()

        XCTAssertFalse(state.pendingICloudRouteIDs.contains(route.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("walk-\(route.id.uuidString.lowercased()).gpx").path))
    }

    @available(iOS, deprecated: 17.0)
    func testInitialReconciliationAdoptsCompleteManifestWithoutRewritingRoute() async throws {
        let route = makeRoute(id: UUID())
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        try await store.saveRoutes([route])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalksGPXAdopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let publisher = ICloudGPXPublisher(exportFolderProvider: { folder })
        _ = try await publisher.publishBatch([route])
        let routeFile = folder.appendingPathComponent("walk-\(route.id.uuidString.lowercased()).gpx")
        let originalModificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: routeFile.path)[.modificationDate] as? Date
        )
        let state = SyncStateStore(defaults: makeDefaults())
        state.save(anchor: HKQueryAnchor(fromValue: 1))
        state.markFullHistoryBackfillComplete()
        state.markWorkoutMetadataBackfillComplete()
        let service = HealthKitService(
            syncState: state,
            queryOverrides: queries(changes: (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 2)), route: { _ in nil }),
            iCloudPublisher: publisher,
            walkStore: store
        )

        let succeeded = await service.syncIncrementally()

        let finalModificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: routeFile.path)[.modificationDate] as? Date
        )
        XCTAssertTrue(succeeded)
        XCTAssertFalse(state.needsInitialICloudReconciliation)
        XCTAssertEqual(finalModificationDate, originalModificationDate)
    }

    func testManualICloudRepairPublishesOnlyRoutesAndReportsCompletion() async throws {
        let route = makeRoute(id: UUID())
        let noRoute = WalkMetadata(
            id: UUID(),
            startDate: route.startDate.addingTimeInterval(-3_600),
            endDate: route.startDate.addingTimeInterval(-1_800)
        )
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        try await store.saveRoutes([route])
        try await store.saveWorkoutMetadata([noRoute])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalksGPXManualRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = SyncStateStore(defaults: makeDefaults())
        state.markInitialICloudReconciliationComplete()
        let service = HealthKitService(
            syncState: state,
            iCloudPublisher: ICloudGPXPublisher(exportFolderProvider: { folder }),
            walkStore: store
        )

        await service.repairICloudExportFolder()

        let manifestData = try Data(contentsOf: folder.appendingPathComponent(ICloudExportConfiguration.manifestFilename))
        let manifest = try ICloudExportManifest.decode(manifestData)
        XCTAssertEqual(manifest.walks.map(\.id), [route.id])
        XCTAssertEqual(service.iCloudExportCompletedRouteCount, 1)
        XCTAssertEqual(service.iCloudExportTotalRouteCount, 1)
        XCTAssertEqual(service.iCloudExportMessage, "Repaired the iCloud Drive folder with 1 walks.")
    }

    func testHealthKitFinishesBeforeICloudAndOverlappingReconciliationIsCoalesced() async {
        let state = SyncStateStore(defaults: makeDefaults())
        state.save(anchor: HKQueryAnchor(fromValue: 1))
        state.markFullHistoryBackfillComplete()
        state.markWorkoutMetadataBackfillComplete()

        var reconciliationPasses = 0
        var reconciliationStarted = false
        var releaseFirstPass: CheckedContinuation<Void, Never>?
        let service = HealthKitService(
            syncState: state,
            queryOverrides: queries(
                changes: (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 2)),
                route: { _ in nil }
            ),
            iCloudReconciliationOverride: {
                reconciliationPasses += 1
                if reconciliationPasses == 1 {
                    reconciliationStarted = true
                    await withCheckedContinuation { releaseFirstPass = $0 }
                }
            }
        )

        let syncTask = Task { await service.syncIncrementally() }
        while !reconciliationStarted { await Task.yield() }

        XCTAssertTrue(service.isSyncInProgress)
        XCTAssertFalse(service.isLoading, "HealthKit must stop showing activity while iCloud reconciliation continues")
        XCTAssertTrue(service.isExportingToICloud)

        await service.retryICloudExport()
        XCTAssertEqual(reconciliationPasses, 1, "A concurrent request should join/coalesce instead of starting a second scan")

        releaseFirstPass?.resume()
        let syncSucceeded = await syncTask.value
        XCTAssertTrue(syncSucceeded)
        XCTAssertEqual(reconciliationPasses, 2, "A request arriving during a scan should cause one follow-up pass")
        XCTAssertFalse(service.isSyncInProgress)
        XCTAssertFalse(service.isLoading)
        XCTAssertFalse(service.isExportingToICloud)
    }

    @available(iOS, deprecated: 17.0)
    func testHistoricalBackfillDoesNotReadRoutesAlreadySaved() async throws {
        let workout = makeWorkout()
        let route = makeRoute(id: workout.uuid)
        try WalkStore.shared.save([route])
        defer { try? WalkStore.shared.delete(ids: [route.id]) }
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        state.markFullHistoryBackfillComplete()
        state.requestFullHistoryBackfill()
        let service = HealthKitService(syncState: state, queryOverrides: queries(
            changes: (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 91)),
            historical: [workout],
            route: { _ in XCTFail("A stored route must not be fetched again during metadata backfill"); return nil }
        ))

        let synced = await service.syncIncrementally()
        let persistedRoute = try await WalkStore.shared.fetchRoute(id: route.id)
        XCTAssertTrue(synced)
        XCTAssertEqual(persistedRoute, route)
        XCTAssertEqual(state.anchor, HKQueryAnchor(fromValue: 91))
    }

    func testIncrementalSyncReportsQueryFailureWithoutAdvancingAnchor() async {
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        let service = HealthKitService(syncState: state, queryOverrides: HealthKitQueryOverrides(
            workoutChanges: { throw QueryError.failed },
            pendingWorkouts: { [] },
            allWalkingWorkouts: { [] },
            route: { _ in nil }
        ))

        let synced = await service.syncIncrementally()

        XCTAssertFalse(synced)
        XCTAssertEqual(service.errorMessage, QueryError.failed.localizedDescription)
        XCTAssertEqual(service.syncMessage, "Sync failed: \(QueryError.failed.localizedDescription)")
        XCTAssertNil(state.anchor)
    }

    @available(iOS, deprecated: 17.0)
    func testIncrementalSyncRouteReadFailureDoesNotCommitAnchorOrLoseWorkout() async throws {
        let workout = makeWorkout()
        let state = SyncStateStore(defaults: makeDefaults())
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let service = HealthKitService(
            syncState: state,
            queryOverrides: queries(
                changes: (added: [workout], deleted: [], anchor: HKQueryAnchor(fromValue: 42)),
                route: { _ in throw QueryError.failed }
            ),
            walkStore: store
        )

        let succeeded = await service.syncIncrementally()
        let count = try await store.fetchWalkCount()
        let summaryPage = try await store.fetchRouteSummaryPage(limit: 10)

        XCTAssertFalse(succeeded)
        XCTAssertNil(state.anchor, "An incomplete route read must not advance the HealthKit anchor")
        XCTAssertEqual(count, 1, "The workout metadata is committed before the route query and remains visible for retry")
        XCTAssertEqual(summaryPage.summaries.map(\.id), [workout.uuid])
        XCTAssertTrue(service.syncMessage?.contains("Sync failed") == true)
        XCTAssertFalse(service.isLoading)
    }

    func testManualICloudRepairFailureLeavesLocalRouteAndRequestsRetry() async throws {
        let route = makeRoute(id: UUID())
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        try await store.saveRoutes([route])
        let state = SyncStateStore(defaults: makeDefaults())
        let failingPublisher = ICloudGPXPublisher(exportFolderProvider: { throw QueryError.failed })
        let service = HealthKitService(syncState: state, iCloudPublisher: failingPublisher, walkStore: store)

        await service.repairICloudExportFolder()

        let localRoute = try await store.fetchRoute(id: route.id)
        XCTAssertEqual(localRoute, route, "iCloud Drive failure must never remove the local Core Data route")
        XCTAssertTrue(state.needsInitialICloudReconciliation, "A failed authoritative scan must remain retryable")
        XCTAssertEqual(service.iCloudExportCompletedRouteCount, 0)
        XCTAssertEqual(service.iCloudExportTotalRouteCount, 1)
        XCTAssertTrue(service.iCloudExportMessage?.contains("iCloud export needs a retry") == true)
        XCTAssertFalse(service.isExportingToICloud)
    }

    func testIncrementalSyncRejectsAnOverlappingRequest() async {
        let service = HealthKitService(presentationState: HealthKitPresentationState(isLoading: true))

        let synced = await service.syncIncrementally()
        XCTAssertFalse(synced)
    }

    func testLoadWalksDelegatesToIncrementalSync() async {
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        let service = HealthKitService(syncState: state, queryOverrides: queries(
            changes: (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 8)),
            route: { _ in nil }
        ))

        await service.loadWalks()

        XCTAssertEqual(state.anchor, HKQueryAnchor(fromValue: 8))
        XCTAssertEqual(service.syncMessage, "No walking workouts are visible. Check Health access for Workouts and Workout Routes, then sync again.")
    }

    func testImportFullHistoryDoesNotStartWhenAnotherSyncIsActive() async {
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        let service = HealthKitService(
            syncState: state,
            presentationState: HealthKitPresentationState(isLoading: true)
        )

        await service.importFullHistory()

        XCTAssertTrue(state.needsFullHistoryBackfill)
        XCTAssertNil(state.anchor)
    }

    func testLoadStoredWalksOnlyRequeuesRouteLessWalksWithoutReplacingAnchor() async throws {
        let route = WalkRoute(
            id: UUID(), startDate: .now.addingTimeInterval(-60), endDate: .now,
            locations: [RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: .now)]
        )
        let missingRoute = WalkMetadata(
            id: UUID(), startDate: .now.addingTimeInterval(-120), endDate: .now.addingTimeInterval(-60)
        )
        try WalkStore.shared.save([route])
        try await WalkStore.shared.saveWorkoutMetadata([missingRoute])
        defer { try? WalkStore.shared.delete(ids: [route.id, missingRoute.id]) }
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        let anchor = HKQueryAnchor(fromValue: 29)
        state.save(anchor: anchor)
        let service = HealthKitService(syncState: state)

        await service.loadStoredWalks()

        XCTAssertFalse(state.pendingRouteIDs.contains(route.id))
        XCTAssertTrue(state.pendingRouteIDs.contains(missingRoute.id))
        XCTAssertEqual(state.anchor, anchor)
    }

    func testHealthKitQueryResultAdaptersCoverEmptySuccessMissingAnchorAndFailure() throws {
        let workout = makeWorkout()
        let anchor = HKQueryAnchor(fromValue: 9)

        let changes = try HealthKitQueryResult.workoutChanges(
            samples: [workout], deleted: [], anchor: anchor, error: nil
        )
        XCTAssertEqual(changes.added.map(\.uuid), [workout.uuid])
        XCTAssertTrue(changes.deleted.isEmpty)
        XCTAssertEqual(changes.anchor, anchor)
        XCTAssertTrue(try HealthKitQueryResult.workouts(samples: nil, error: nil).isEmpty)
        XCTAssertEqual(try HealthKitQueryResult.workouts(samples: [workout], error: nil), [workout])
        XCTAssertNil(try HealthKitQueryResult.routeSamples(samples: [], error: nil))
        XCTAssertNil(try HealthKitQueryResult.routeSamples(samples: [workout], error: nil))

        XCTAssertThrowsError(try HealthKitQueryResult.workoutChanges(
            samples: nil, deleted: nil, anchor: nil, error: nil
        )) { error in
            guard let syncError = error as? SyncError, case .missingAnchor = syncError else {
                return XCTFail("Missing anchors should map to SyncError.missingAnchor")
            }
        }
        XCTAssertThrowsError(try HealthKitQueryResult.workouts(samples: nil, error: QueryError.failed))
        XCTAssertThrowsError(try HealthKitQueryResult.routeSamples(samples: nil, error: QueryError.failed))
    }

    func testHealthKitQueryCompletionHandlersResumeWithMappedResultsAndErrors() {
        let workout = makeWorkout()
        let anchor = HKQueryAnchor(fromValue: 17)
        let anchoredQuery = HKAnchoredObjectQuery(
            type: .workoutType(), predicate: nil, anchor: nil, limit: 1,
            resultsHandler: { _, _, _, _, _ in }
        )
        let changesResult = SendableBox<Result<HealthKitQueryResult.WorkoutChanges, Error>>()
        let changesHandler = HealthKitQueryResult.workoutChangesHandler { changesResult.set($0) }
        changesHandler(anchoredQuery, [workout], [], anchor, nil)
        switch changesResult.value {
        case .success(let changes):
            XCTAssertEqual(changes.added.map(\.uuid), [workout.uuid])
            XCTAssertEqual(changes.anchor, anchor)
        case .failure(let error): XCTFail("Unexpected query error: \(error)")
        case nil: XCTFail("The HealthKit completion handler must resume its continuation")
        }

        let sampleQuery = HKSampleQuery(sampleType: .workoutType(), predicate: nil, limit: 1, sortDescriptors: nil) { _, _, _ in }
        let workoutResult = SendableBox<Result<[HKWorkout], Error>>()
        let workoutHandler = HealthKitQueryResult.workoutsHandler { workoutResult.set($0) }
        workoutHandler(sampleQuery, [workout], nil)
        XCTAssertEqual(try? workoutResult.value?.get().map(\.uuid), [workout.uuid])
        workoutHandler(sampleQuery, nil, QueryError.failed)
        if case .failure(let error) = workoutResult.value {
            XCTAssertEqual(error.localizedDescription, QueryError.failed.localizedDescription)
        } else {
            XCTFail("HealthKit errors must be propagated to the caller")
        }
    }

    func testHealthKitRouteResultFiltersInvalidPointsAndPreservesWorkoutIdentity() throws {
        let workout = makeWorkout()
        let start = workout.startDate
        let onePoint = [makeLocation(latitude: 51.5, longitude: -0.12, timestamp: start)]
        XCTAssertNil(HealthKitQueryResult.route(workout: workout, locations: onePoint))

        let locations = [
            makeLocation(latitude: 91, longitude: 0, timestamp: start),
            makeLocation(latitude: 51.5, longitude: -0.12, timestamp: start),
            makeLocation(latitude: 51.501, longitude: -0.121, timestamp: start.addingTimeInterval(60))
        ]
        let route = try XCTUnwrap(HealthKitQueryResult.route(workout: workout, locations: locations))
        XCTAssertEqual(route.id, workout.uuid)
        XCTAssertEqual(route.startDate, workout.startDate)
        XCTAssertEqual(route.endDate, workout.endDate)
        XCTAssertEqual(route.locations.count, 2)
    }

    func testRouteBatchUpdateMapsPendingFailureAndCompletionStates() {
        let workout = makeWorkout()
        let pending = HealthKitQueryResult.routeBatchUpdate(.pending, workout: workout)
        if case .pending = pending {} else { XCTFail("Incomplete batches must remain pending") }
        let ignored = HealthKitQueryResult.routeBatchUpdate(.ignored, workout: workout)
        if case .pending = ignored {} else { XCTFail("Late callbacks must be ignored") }
        let failure = HealthKitQueryResult.routeBatchUpdate(.failed(QueryError.failed), workout: workout)
        if case .failed(let error) = failure {
            XCTAssertEqual(error.localizedDescription, QueryError.failed.localizedDescription)
        } else {
            XCTFail("Route query errors must propagate")
        }
        let emptyCompletion = HealthKitQueryResult.routeBatchUpdate(.completed([]), workout: workout)
        if case .finished(let route) = emptyCompletion { XCTAssertNil(route) }
        else { XCTFail("A completed batch without readable points must produce no route") }
        let start = workout.startDate
        let completed = HealthKitQueryResult.routeBatchUpdate(.completed([
            makeLocation(latitude: 51.5, longitude: -0.12, timestamp: start),
            makeLocation(latitude: 51.501, longitude: -0.121, timestamp: start.addingTimeInterval(60))
        ]), workout: workout)
        if case .finished(let route) = completed { XCTAssertEqual(route?.id, workout.uuid) }
        else { XCTFail("A completed valid batch must produce a route") }
    }

    func testRouteLocationsCompletionHandlerAccumulatesMultipleCallbacksAndPropagatesErrors() {
        let workout = makeWorkout()
        let start = workout.startDate
        let accumulator = RouteBatchAccumulator(routeCount: 1)
        let result = SendableBox<Result<WalkRoute?, Error>>()
        let handler = HealthKitQueryResult.routeLocationsHandler(
            workout: workout,
            accumulator: accumulator
        ) { result.set($0) }

        handler([makeLocation(latitude: 51.5, longitude: -0.12, timestamp: start)], false, nil)
        XCTAssertNil(result.value, "A partial HealthKit route callback must not finish early")
        handler([makeLocation(latitude: 51.501, longitude: -0.121, timestamp: start.addingTimeInterval(60))], true, nil)
        switch result.value {
        case .success(let route): XCTAssertEqual(route?.locations.count, 2)
        case .failure(let error): XCTFail("Unexpected route error: \(error)")
        case nil: XCTFail("The final route callback must finish the result")
        }

        let failedResult = SendableBox<Result<WalkRoute?, Error>>()
        let failingHandler = HealthKitQueryResult.routeLocationsHandler(
            workout: workout,
            accumulator: RouteBatchAccumulator(routeCount: 1)
        ) { failedResult.set($0) }
        failingHandler(nil, false, QueryError.failed)
        if case .failure(let error) = failedResult.value {
            XCTAssertEqual(error.localizedDescription, QueryError.failed.localizedDescription)
        } else {
            XCTFail("A HealthKit route query error must propagate")
        }
    }

    func testRouteSampleAndMultiRouteQueryHandlersCoverEmptyAndCompletePaths() {
        let workout = makeWorkout()
        let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: nil, limit: 1, sortDescriptors: nil) { _, _, _ in }
        let sampleResult = SendableBox<Result<WalkRoute?, Error>>()
        let sampleHandler = HealthKitQueryResult.routeSamplesHandler(
            workout: workout,
            executeRouteQuery: { _, _, _ in XCTFail("No HealthKit route samples means no route query") },
            complete: { sampleResult.set($0) }
        )
        sampleHandler(query, [], nil)
        if case .success(let route) = sampleResult.value { XCTAssertNil(route) }
        else { XCTFail("An empty route sample result should finish with no route") }

        let errorResult = SendableBox<Result<WalkRoute?, Error>>()
        let failingSampleHandler = HealthKitQueryResult.routeSamplesHandler(
            workout: workout,
            executeRouteQuery: { _, _, _ in XCTFail("An errored route sample query must not start route reads") },
            complete: { errorResult.set($0) }
        )
        failingSampleHandler(query, nil, QueryError.failed)
        if case .failure(let error) = errorResult.value {
            XCTAssertEqual(error.localizedDescription, QueryError.failed.localizedDescription)
        } else {
            XCTFail("Route sample errors must propagate")
        }

        let executedIndexes = SendableBox<[Int]>([])
        let multiRouteResult = SendableBox<Result<WalkRoute?, Error>>()
        let start = workout.startDate
        let routeLocations = (0..<2).map { index in
            let latitude = 51.5 + Double(index) * 0.01
            return [
                makeLocation(latitude: latitude, longitude: -0.12, timestamp: start),
                makeLocation(latitude: latitude + 0.001, longitude: -0.121, timestamp: start.addingTimeInterval(60))
            ]
        }
        let routeLocationsBox = SendableBox(routeLocations)
        HealthKitQueryResult.runRouteQueries(
            workout: workout,
            routeCount: 2,
            executeRouteQuery: { index, handler in
                executedIndexes.update { $0.append(index) }
                handler(routeLocationsBox.value![index], true, nil)
            },
            complete: { multiRouteResult.set($0) }
        )
        XCTAssertEqual(executedIndexes.value, [0, 1])
        if case .success(let route) = multiRouteResult.value { XCTAssertEqual(route?.locations.count, 4) }
        else { XCTFail("All route samples should be combined into one workout route") }

        let emptyResult = SendableBox<Result<WalkRoute?, Error>>()
        HealthKitQueryResult.runRouteQueries(
            workout: workout,
            routeCount: 0,
            executeRouteQuery: { _, _ in XCTFail("An empty route count must not query HealthKit") },
            complete: { emptyResult.set($0) }
        )
        if case .success(let route) = emptyResult.value { XCTAssertNil(route) }
        else { XCTFail("Zero route queries should finish successfully without a route") }
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func makeWorkout() -> HKWorkout {
        HKWorkout(activityType: .walking, start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 61))
    }

    private func makeRoute(id: UUID) -> WalkRoute {
        let start = Date(timeIntervalSince1970: 1)
        return WalkRoute(id: id, startDate: start, endDate: start.addingTimeInterval(60), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(60))
        ])
    }

    private func makeLocation(latitude: Double, longitude: Double, timestamp: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: timestamp
        )
    }

    private func queries(
        changes: (added: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor),
        historical: [HKWorkout] = [],
        route: @escaping (HKWorkout) async throws -> WalkRoute?
    ) -> HealthKitQueryOverrides {
        HealthKitQueryOverrides(
            workoutChanges: { changes },
            pendingWorkouts: { [] },
            allWalkingWorkouts: { historical },
            route: route
        )
    }
}

private enum AuthorizationError: LocalizedError {
    case denied

    var errorDescription: String? { "Health access was denied for this test." }
}

private enum QueryError: LocalizedError {
    case failed

    var errorDescription: String? { "The HealthKit query failed for this test." }
}

private final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    init(_ value: Value? = nil) { storedValue = value }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storedValue = value
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var storedValue else { return }
        body(&storedValue)
        self.storedValue = storedValue
    }
}
