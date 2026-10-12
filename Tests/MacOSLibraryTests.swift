import AppKit
import SwiftUI
import XCTest
@testable import WalksGPX_macOS

@MainActor
final class MacOSLibraryTests: XCTestCase {
    private var windows: [NSWindow] = []

    func testMacTargetLoadsPagedSummariesWithoutEagerRoutes() async throws {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = (0..<3).map { offset in
            WalkMetadata(
                id: UUID(),
                startDate: start.addingTimeInterval(TimeInterval(offset * 60)),
                endDate: start.addingTimeInterval(TimeInterval((offset + 1) * 60))
            )
        }
        try await store.saveWorkoutMetadata(metadata)

        let library = WalkLibraryModel(store: store, pageSize: 2)
        await library.refresh(force: true)

        XCTAssertEqual(library.walks.count, 2)
        XCTAssertTrue(library.hasMore)
        XCTAssertTrue(library.walks.allSatisfy { !$0.hasGPSRoute })
        let route = try await store.fetchRoute(id: metadata[0].id)
        XCTAssertNil(route, "Paging metadata must not synthesize or eagerly fetch a GPS route")

        await library.loadNextPage()
        XCTAssertEqual(library.walks.count, 3)
        XCTAssertFalse(library.hasMore)
    }

    func testMacDetailLoadsSelectedRouteAndExportsOnlyOnDemand() async throws {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = WalkRoute(id: UUID(), startDate: start, endDate: start.addingTimeInterval(60), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(60))
        ])
        try await store.saveRoutes([route])
        let summary = WalkRouteSummary(id: route.id, startDate: route.startDate, endDate: route.endDate, hasGPSRoute: true)
        let detail = WalkDetailModel(store: store)

        await detail.load(summary)

        XCTAssertEqual(detail.state, .ready)
        XCTAssertEqual(detail.route, route)
        let data = try await detail.exportData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("<trkseg>"))
        XCTAssertTrue(text.contains("lat=\"51.5\""))
    }

    func testMacDetailReportsMissingRouteAsUnavailable() async {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = WalkRouteSummary(id: UUID(), startDate: date, endDate: date.addingTimeInterval(60), hasGPSRoute: false)
        let detail = WalkDetailModel(store: store)

        await detail.load(summary)

        XCTAssertEqual(detail.state, .routeUnavailable)
        XCTAssertNil(detail.route)
    }

    func testMacStoreRouteIndexesCountsAndBatchReadsStayConsistent() async throws {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let routeID = UUID()
        let unavailableID = UUID()
        let unknownID = UUID()
        let route = WalkRoute(id: routeID, startDate: date, endDate: date.addingTimeInterval(90), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: date),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: date.addingTimeInterval(90))
        ])
        try await store.saveWorkoutMetadata([
            WalkMetadata(id: routeID, startDate: route.startDate, endDate: route.endDate),
            WalkMetadata(id: unavailableID, startDate: date.addingTimeInterval(-60), endDate: date),
            WalkMetadata(id: unknownID, startDate: date.addingTimeInterval(-120), endDate: date)
        ])
        try await store.markRoutesUnavailable(ids: [unavailableID])
        try await store.saveRoutes([route])

        let indexedRouteIDs = try await store.fetchRouteIDs(for: [routeID, unavailableID, UUID()])
        let retryCandidates = try await store.fetchRouteReadCandidateIDs(for: [routeID, unavailableID, unknownID])
        let routeReadyIDs = try await store.fetchAllRouteIDs()
        let unavailableIDs = try await store.fetchAllRouteIDs(requiringGPSRoute: false)
        let batchRoutes = try await store.fetchRoutes(ids: [routeID, unavailableID])
        let totalCount = try await store.fetchWalkCount()
        let routeCount = try await store.fetchWalkCount(requiringGPSRoute: true)
        let unavailableCount = try await store.fetchWalkCount(requiringGPSRoute: false)
        XCTAssertEqual(indexedRouteIDs, [routeID])
        XCTAssertEqual(retryCandidates, [unknownID])
        XCTAssertEqual(routeReadyIDs, [routeID])
        XCTAssertEqual(unavailableIDs, [unknownID, unavailableID])
        XCTAssertEqual(batchRoutes, [route])
        XCTAssertEqual(totalCount, 3)
        XCTAssertEqual(routeCount, 1)
        XCTAssertEqual(unavailableCount, 2)
        XCTAssertEqual(store.fetchRoutes(), [route])
        XCTAssertEqual(WalkRouteSummary(id: routeID, startDate: date, endDate: date.addingTimeInterval(1), hasGPSRoute: true).filename, route.filename)

        try store.delete(ids: [unknownID])
        let countAfterDeletion = try await store.fetchWalkCount()
        XCTAssertEqual(countAfterDeletion, 2)
    }

    func testMacLibraryScreenRendersEmptyAndPopulatedStates() async throws {
        let emptyStore = WalkStore(inMemory: true)
        await emptyStore.waitUntilReady()
        let emptyLibrary = WalkLibraryModel(store: emptyStore)
        await emptyLibrary.refresh(force: true)
        let emptyHost = show(ContentView(library: emptyLibrary))
        emptyHost.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(emptyHost.view.bounds.width, 0)

        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = WalkRoute(id: UUID(), startDate: start, endDate: start.addingTimeInterval(3_600), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(3_600))
        ])
        let previousDay = start.addingTimeInterval(-86_400)
        let earlierRoute = WalkRoute(id: UUID(), startDate: previousDay, endDate: previousDay.addingTimeInterval(1_800), locations: [
            RouteLocation(latitude: 51.49, longitude: -0.11, elevation: nil, timestamp: previousDay),
            RouteLocation(latitude: 51.491, longitude: -0.111, elevation: nil, timestamp: previousDay.addingTimeInterval(1_800))
        ])
        try await store.saveRoutes([route, earlierRoute])
        let library = WalkLibraryModel(store: store)
        await library.refresh(force: true)
        let host = show(ContentView(library: library))
        host.view.layoutSubtreeIfNeeded()
        for _ in 0..<20 where library.selectedWalk == nil { await Task.yield() }

        XCTAssertEqual(library.walks.count, 2)
        XCTAssertEqual(library.selectedWalk?.id, route.id, "The Mac library should select the newest walk when first opened")
        XCTAssertGreaterThan(host.view.bounds.height, 0)
    }

    func testMacFilterSheetAndImportedGPXDetailRender() {
        XCTAssertEqual(WalkLibraryFilterSheet.durationFilter(for: WalkSearchFilter()), .any)
        XCTAssertEqual(WalkLibraryFilterSheet.durationFilter(for: WalkSearchFilter(maximumDuration: 1_799)), .underThirtyMinutes)
        XCTAssertEqual(WalkLibraryFilterSheet.durationFilter(for: WalkSearchFilter(minimumDuration: 1_800, maximumDuration: 3_599)), .thirtyToSixtyMinutes)
        XCTAssertEqual(WalkLibraryFilterSheet.durationFilter(for: WalkSearchFilter(minimumDuration: 3_600, maximumDuration: 7_199)), .oneToTwoHours)
        XCTAssertEqual(WalkLibraryFilterSheet.durationFilter(for: WalkSearchFilter(minimumDuration: 7_200)), .overTwoHours)
        XCTAssertEqual(WalkLibraryFilterSheet.durationFilter(for: WalkSearchFilter(minimumDuration: 100, maximumDuration: 200)), .any)

        let filterHost = show(WalkLibraryFilterSheet(filter: WalkSearchFilter(minimumDuration: 1_800)) { _ in })
        filterHost.view.layoutSubtreeIfNeeded()
        let library = WalkLibraryModel(store: WalkStore(inMemory: true))
        let content = ContentView(library: library)
        let file = ImportedGPXFile(id: "/test/route.gpx", name: "route.gpx", data: Data("<gpx/>".utf8))
        let importedHost = show(content.importedFileDetail(file))
        importedHost.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(filterHost.view.bounds.width, 0)
        XCTAssertGreaterThan(importedHost.view.bounds.width, 0)
    }

    func testMacSelectionBindingKeepsWalkAndImportedFileDetailsInSync() async throws {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let route = WalkRoute(id: UUID(), startDate: date, endDate: date.addingTimeInterval(60), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: date),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: date.addingTimeInterval(60))
        ])
        try await store.saveRoutes([route])
        let library = WalkLibraryModel(store: store)
        await library.refresh(force: true)
        let importedFile = ImportedGPXFile(id: "/tmp/sample.gpx", name: "sample.gpx", data: Data("<gpx/>".utf8))
        let content = ContentView(library: library, importedFiles: [importedFile])
        let host = show(content)

        content.selectionBinding.wrappedValue = .walk(route.id)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(library.selectedWalk?.id, route.id)

        content.selectionBinding.wrappedValue = .file(importedFile.id)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertNil(library.selectedWalk)

        content.selectionBinding.wrappedValue = nil
        XCTAssertNil(library.selectedWalk)
    }

    func testMacContextExportLoadsSelectedRouteBeforeInvokingExporter() async throws {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let route = WalkRoute(id: UUID(), startDate: date, endDate: date.addingTimeInterval(60), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: date),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: date.addingTimeInterval(60))
        ])
        try await store.saveRoutes([route])
        let library = WalkLibraryModel(store: store)
        await library.refresh(force: true)
        let summary = try XCTUnwrap(library.walks.first)
        let exportInvoked = expectation(description: "Export is invoked after the route is loaded")
        var exportedRoute: WalkRoute?
        let content = ContentView(library: library, onExportRoute: { route in
            exportedRoute = route
            exportInvoked.fulfill()
        })

        content.exportWalk(summary)

        await fulfillment(of: [exportInvoked], timeout: 2)
        XCTAssertEqual(exportedRoute, route)
    }

    private func show<Content: View>(_ content: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: content)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        windows.append(window)
        return controller
    }
}
