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

    func testProgressHandlesEmptyAndClampsBounds() {
        XCTAssertEqual(SyncProgress(processed: 0, total: 0).fraction, 0)
        XCTAssertEqual(SyncProgress(processed: 2, total: 4).fraction, 0.5)
        XCTAssertEqual(SyncProgress(processed: 8, total: 4).fraction, 1)
        XCTAssertEqual(SyncProgress(processed: -1, total: 4).fraction, 0)
    }
}
