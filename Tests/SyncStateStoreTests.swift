import XCTest
import HealthKit
@testable import WalksGPX_iOS

final class SyncStateStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WalksGPXTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testNewStateHasNoAnchorOrLastSyncDate() {
        let state = SyncStateStore(defaults: defaults)

        XCTAssertNil(state.anchor)
        XCTAssertNil(state.lastSyncDate)
    }

    func testSavedAnchorAndDateRoundTrip() {
        let state = SyncStateStore(defaults: defaults)
        let anchor = HKQueryAnchor(fromValue: 42)
        let pendingID = UUID()
        let date = Date(timeIntervalSince1970: 1234)

        state.save(anchor: anchor, pendingRouteIDs: [pendingID], at: date)

        XCTAssertEqual(state.anchor, anchor)
        XCTAssertEqual(state.pendingRouteIDs, [pendingID])
        XCTAssertEqual(state.lastSyncDate, date)
    }

    func testPendingRouteIDsCanBeAddedWithoutLosingAnchor() {
        let state = SyncStateStore(defaults: defaults)
        let anchor = HKQueryAnchor(fromValue: 42)
        let firstID = UUID()
        let secondID = UUID()
        state.save(anchor: anchor, pendingRouteIDs: [firstID])

        state.addPendingRouteIDs([secondID])

        XCTAssertEqual(state.anchor, anchor)
        XCTAssertEqual(state.pendingRouteIDs, [firstID, secondID])
    }

    func testRouteBatchRepairFlagPersists() {
        let state = SyncStateStore(defaults: defaults)

        XCTAssertTrue(state.needsRouteBatchRepair)
        state.markRouteBatchRepairComplete()

        XCTAssertFalse(SyncStateStore(defaults: defaults).needsRouteBatchRepair)
    }

    func testFullHistoryBackfillCanBeRequestedAgainWithoutClearingAnchor() {
        let state = SyncStateStore(defaults: defaults)
        let anchor = HKQueryAnchor(fromValue: 42)
        state.save(anchor: anchor)
        state.markFullHistoryBackfillComplete()

        state.requestFullHistoryBackfill()

        XCTAssertTrue(state.needsFullHistoryBackfill)
        XCTAssertEqual(state.anchor, anchor)
    }

    func testWorkoutMetadataBackfillFlagIsIndependentFromRouteBackfill() {
        let state = SyncStateStore(defaults: defaults)

        XCTAssertTrue(state.needsWorkoutMetadataBackfill)
        state.markWorkoutMetadataBackfillComplete()
        XCTAssertFalse(state.needsWorkoutMetadataBackfill)
        XCTAssertTrue(state.needsFullHistoryBackfill)

        state.reset()
        XCTAssertTrue(state.needsWorkoutMetadataBackfill)
    }

    func testResetRemovesSavedSyncState() {
        let state = SyncStateStore(defaults: defaults)
        state.save(anchor: HKQueryAnchor(fromValue: 7), at: Date())

        state.reset()

        XCTAssertNil(state.anchor)
        XCTAssertTrue(state.pendingRouteIDs.isEmpty)
        XCTAssertNil(state.lastSyncDate)
    }

    func testConnectedFlagPersistsAndResets() {
        let state = SyncStateStore(defaults: defaults)

        XCTAssertFalse(state.hasConnected)
        state.markConnected()
        XCTAssertTrue(SyncStateStore(defaults: defaults).hasConnected)

        state.reset()
        XCTAssertFalse(SyncStateStore(defaults: defaults).hasConnected)
    }

    func testLegacyAnchorStateIsReadable() {
        let state = SyncStateStore(defaults: defaults)
        let anchor = HKQueryAnchor(fromValue: 9)
        let anchorData = try! NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        defaults.set(anchorData, forKey: "healthKit.workoutAnchor")
        defaults.set(Date(timeIntervalSince1970: 55), forKey: "healthKit.lastSyncDate")

        XCTAssertEqual(state.anchor, anchor)
        XCTAssertTrue(state.pendingRouteIDs.isEmpty)
        XCTAssertEqual(state.lastSyncDate, Date(timeIntervalSince1970: 55))
    }

    func testCorruptCurrentStateFallsBackToLegacyCheckpoint() {
        let state = SyncStateStore(defaults: defaults)
        let anchor = HKQueryAnchor(fromValue: 19)
        defaults.set(Data("not-json".utf8), forKey: "healthKit.syncState")
        defaults.set(try! NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true), forKey: "healthKit.workoutAnchor")

        XCTAssertEqual(state.anchor, anchor)
        XCTAssertTrue(state.pendingRouteIDs.isEmpty)
        XCTAssertTrue(state.hasConnected)
    }

    func testAddingNoPendingIDsPreservesState() {
        let state = SyncStateStore(defaults: defaults)
        let anchor = HKQueryAnchor(fromValue: 3)
        let date = Date(timeIntervalSince1970: 8)
        state.save(anchor: anchor, pendingRouteIDs: [UUID()], at: date)

        state.addPendingRouteIDs([])

        XCTAssertEqual(state.anchor, anchor)
        XCTAssertEqual(state.lastSyncDate, date)
    }

    func testICloudExportJournalSurvivesRelaunchAndAcknowledgesWorkIndependently() {
        let state = SyncStateStore(defaults: defaults)
        let routeID = UUID()
        let deletedID = UUID()
        state.enqueueICloudRouteIDs([routeID])
        state.enqueueICloudDeletionIDs([deletedID])

        let relaunched = SyncStateStore(defaults: defaults)
        XCTAssertEqual(relaunched.pendingICloudRouteIDs, [routeID])
        XCTAssertEqual(relaunched.pendingICloudDeletionIDs, [deletedID])

        relaunched.acknowledgeICloudRouteIDs([routeID])
        XCTAssertTrue(relaunched.pendingICloudRouteIDs.isEmpty)
        XCTAssertEqual(relaunched.pendingICloudDeletionIDs, [deletedID])
    }

    func testDeletingAnIDRemovesAnyQueuedExportForThatID() {
        let state = SyncStateStore(defaults: defaults)
        let id = UUID()
        state.enqueueICloudRouteIDs([id])

        state.enqueueICloudDeletionIDs([id])

        XCTAssertTrue(state.pendingICloudRouteIDs.isEmpty)
        XCTAssertEqual(state.pendingICloudDeletionIDs, [id])
    }

    func testICloudAcknowledgementsRemoveOnlyCompletedIDsAndAreIdempotent() {
        let state = SyncStateStore(defaults: defaults)
        let routeIDs = [UUID(), UUID(), UUID()]
        let deletionIDs = [UUID(), UUID(), UUID()]
        state.enqueueICloudRouteIDs(Set(routeIDs))
        state.enqueueICloudDeletionIDs(Set(deletionIDs))

        state.acknowledgeICloudRouteIDs([routeIDs[0], UUID()])
        state.acknowledgeICloudDeletionIDs([deletionIDs[1], UUID()])
        state.acknowledgeICloudDeletionIDs([deletionIDs[1]])

        XCTAssertEqual(state.pendingICloudRouteIDs, Set(routeIDs.dropFirst()))
        XCTAssertEqual(state.pendingICloudDeletionIDs, Set([deletionIDs[0], deletionIDs[2]]))
    }

    func testInitialICloudReconciliationMarkerPersists() {
        let state = SyncStateStore(defaults: defaults)

        XCTAssertTrue(state.needsInitialICloudReconciliation)
        state.markInitialICloudReconciliationComplete()

        XCTAssertFalse(SyncStateStore(defaults: defaults).needsInitialICloudReconciliation)
    }

    func testProgressHandlesEmptyAndClampsBounds() {
        XCTAssertEqual(SyncProgress(processed: 0, total: 0).fraction, 0)
        XCTAssertEqual(SyncProgress(processed: 2, total: 4).fraction, 0.5)
        XCTAssertEqual(SyncProgress(processed: 8, total: 4).fraction, 1)
        XCTAssertEqual(SyncProgress(processed: -1, total: 4).fraction, 0)
    }
}
