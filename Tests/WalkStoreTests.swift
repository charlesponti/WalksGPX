import XCTest
@testable import WalksGPX_iOS

@MainActor
final class WalkStoreTests: XCTestCase {
    private var store: WalkStore!

    override func setUp() async throws {
        store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        try XCTSkipIf(store.loadError != nil, "In-memory Core Data store could not be loaded: \(String(describing: store.loadError))")
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    func testSaveFetchUpdateAndDeleteRoutes() throws {
        let older = route(start: Date(timeIntervalSince1970: 10), latitude: 1)
        let newer = route(start: Date(timeIntervalSince1970: 20), latitude: 2)

        try store.save([older, newer])
        XCTAssertEqual(store.fetchRoutes().map(\.id), [newer.id, older.id])

        let revisedOlder = WalkRoute(id: older.id, startDate: older.startDate, endDate: older.endDate, locations: [
            RouteLocation(latitude: 3, longitude: 4, elevation: nil, timestamp: older.startDate)
        ])
        try store.save([revisedOlder])
        XCTAssertEqual(store.fetchRoutes().count, 2)
        XCTAssertEqual(store.fetchRoutes().last?.locations.first?.latitude, 3)

        try store.delete(ids: [newer.id])
        XCTAssertEqual(store.fetchRoutes(), [revisedOlder])
    }

    func testEmptySaveAndDeleteAreNoOps() throws {
        try store.save([])
        try store.delete(ids: [])
        XCTAssertTrue(store.fetchRoutes().isEmpty)
    }

    func testCorruptStoredLocationsAreNotReturned() throws {
        let object = PersistedWalk(context: store.container.viewContext)
        object.id = UUID()
        object.startDate = Date()
        object.endDate = Date()
        object.locationsData = Data("not-json".utf8)
        try store.container.viewContext.save()

        XCTAssertTrue(store.fetchRoutes().isEmpty)
    }

    private func route(start: Date, latitude: Double) -> WalkRoute {
        WalkRoute(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(60),
            locations: [RouteLocation(latitude: latitude, longitude: 0, elevation: nil, timestamp: start)]
        )
    }
}
