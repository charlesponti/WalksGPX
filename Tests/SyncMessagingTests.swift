import XCTest
@testable import WalksGPX_iOS

final class SyncMessagingTests: XCTestCase {
    func testStartingMessagesPrioritizeFullHistoryThenPendingRoutes() {
        XCTAssertEqual(SyncMessaging.starting(backfillingHistory: true, queuedRouteCount: 4), "Scanning your full HealthKit walking history…")
        XCTAssertEqual(SyncMessaging.starting(backfillingHistory: false, queuedRouteCount: 4), "Loading 4 saved walks to repair…")
        XCTAssertEqual(SyncMessaging.starting(backfillingHistory: false, queuedRouteCount: 0), "Checking HealthKit…")
    }

    func testFoundWorkoutsHandlesEmptySingularAndPlural() {
        XCTAssertEqual(SyncMessaging.foundWorkouts(0), "No new walking workouts found.")
        XCTAssertEqual(SyncMessaging.foundWorkouts(1), "Found 1 walking workout. Reading GPS routes…")
        XCTAssertEqual(SyncMessaging.foundWorkouts(2), "Found 2 walking workouts. Reading GPS routes…")
    }

    func testCompletedMessagesCoverMissingPendingAndSavedRoutes() {
        XCTAssertTrue(SyncMessaging.completed(savedRouteCount: 0, workoutCount: 3, pendingRouteCount: 0).contains("HealthKit returned 3 workouts"))
        XCTAssertTrue(SyncMessaging.completed(savedRouteCount: 0, workoutCount: 0, pendingRouteCount: 1).contains("No walking workouts"))
        XCTAssertTrue(SyncMessaging.completed(savedRouteCount: 2, workoutCount: 2, pendingRouteCount: 1).contains("1 workouts still"))
        XCTAssertEqual(SyncMessaging.completed(savedRouteCount: 1, workoutCount: 1, pendingRouteCount: 0), "Saved 1 GPS route.")
        XCTAssertEqual(SyncMessaging.completed(savedRouteCount: 2, workoutCount: 2, pendingRouteCount: 0), "Saved 2 GPS routes.")
    }
}
