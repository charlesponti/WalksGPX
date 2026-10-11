import HealthKit
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
        XCTAssertTrue(synced)
        XCTAssertEqual(service.walks.first(where: { $0.id == route.id }), route)
        XCTAssertTrue(state.pendingRouteIDs.isEmpty)
        XCTAssertEqual(state.anchor, HKQueryAnchor(fromValue: 1))
    }

    @available(iOS, deprecated: 17.0)
    func testIncrementalSyncQueuesWorkoutWhoseRouteIsNotYetReadable() async throws {
        let workout = makeWorkout()
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        let service = HealthKitService(syncState: state, queryOverrides: queries(
            changes: (added: [workout], deleted: [], anchor: HKQueryAnchor(fromValue: 2)),
            route: { _ in nil }
        ))
        let synced = await service.syncIncrementally()
        XCTAssertTrue(synced)
        XCTAssertEqual(service.pendingRouteCount, 1)
        XCTAssertEqual(state.pendingRouteIDs, [workout.uuid])
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

    func testLoadStoredWalksRequeuesIncompleteRoutesWithoutReplacingAnchor() async throws {
        let route = WalkRoute(
            id: UUID(), startDate: .now.addingTimeInterval(-60), endDate: .now,
            locations: [RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: .now)]
        )
        try WalkStore.shared.save([route])
        defer { try? WalkStore.shared.delete(ids: [route.id]) }
        let defaults = makeDefaults()
        let state = SyncStateStore(defaults: defaults)
        let anchor = HKQueryAnchor(fromValue: 29)
        state.save(anchor: anchor)
        let service = HealthKitService(syncState: state)

        service.loadStoredWalks()

        XCTAssertTrue(service.walks.contains(where: { $0.id == route.id }))
        XCTAssertTrue(state.pendingRouteIDs.contains(route.id))
        XCTAssertEqual(state.anchor, anchor)
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

    private func queries(
        changes: (added: [HKWorkout], deleted: [HKDeletedObject], anchor: HKQueryAnchor),
        route: @escaping (HKWorkout) async throws -> WalkRoute?
    ) -> HealthKitQueryOverrides {
        HealthKitQueryOverrides(
            workoutChanges: { changes },
            pendingWorkouts: { [] },
            allWalkingWorkouts: { [] },
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
