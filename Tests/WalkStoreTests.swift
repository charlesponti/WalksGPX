import CoreData
import CloudKit
import XCTest
#if os(iOS)
@testable import WalksGPX_iOS
#else
@testable import WalksGPX_macOS
#endif

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

    func testWorkoutMetadataPersistsWithoutRouteAndRouteCanArriveLater() async throws {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 100)
        let metadata = WalkMetadata(id: id, startDate: start, endDate: start.addingTimeInterval(3_600))

        try await store.saveWorkoutMetadata([metadata])
        let routeLess = try await store.fetchRouteSummaryPage(limit: 10)
        let missingRoute = try await store.fetchRoute(id: id)
        XCTAssertEqual(routeLess.summaries.map(\.id), [id])
        XCTAssertFalse(routeLess.summaries[0].hasGPSRoute)
        XCTAssertNil(missingRoute)

        let route = WalkRoute(id: id, startDate: start, endDate: metadata.endDate, locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 51.51, longitude: -0.11, elevation: nil, timestamp: metadata.endDate)
        ])
        try store.save([route])

        let upgraded = try await store.fetchRouteSummaryPage(limit: 10)
        let loadedRoute = try await store.fetchRoute(id: id)
        XCTAssertEqual(upgraded.summaries.map(\.id), [id])
        XCTAssertTrue(upgraded.summaries[0].hasGPSRoute)
        XCTAssertEqual(loadedRoute, route)
    }

    func testRouteReadCandidatesRememberConfirmedNoRouteAndRetryUnknown() async throws {
        let start = Date(timeIntervalSince1970: 100)
        let unknownID = UUID()
        let confirmedNoRouteID = UUID()
        try await store.saveWorkoutMetadata([
            WalkMetadata(id: unknownID, startDate: start, endDate: start.addingTimeInterval(60)),
            WalkMetadata(id: confirmedNoRouteID, startDate: start, endDate: start.addingTimeInterval(120))
        ])

        let beforeLookup = try await store.fetchRouteReadCandidateIDs(for: [unknownID, confirmedNoRouteID])
        XCTAssertEqual(beforeLookup, [unknownID, confirmedNoRouteID])

        try await store.markRoutesUnavailable(ids: [confirmedNoRouteID])
        let afterLookup = try await store.fetchRouteReadCandidateIDs(for: [unknownID, confirmedNoRouteID])

        XCTAssertEqual(afterLookup, [unknownID])
        let unavailable = try await store.fetchRouteSummaryPage(limit: 10, filter: WalkSearchFilter(requiresGPSRoute: false))
        XCTAssertTrue(unavailable.summaries.contains { $0.id == confirmedNoRouteID })
    }

    func testRouteIndexesCountsAndBatchReadsStayConsistent() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let routeID = UUID()
        let unavailableID = UUID()
        let unknownID = UUID()
        let route = WalkRoute(id: routeID, startDate: start, endDate: start.addingTimeInterval(90), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(90))
        ])
        try await store.saveWorkoutMetadata([
            WalkMetadata(id: routeID, startDate: route.startDate, endDate: route.endDate),
            WalkMetadata(id: unavailableID, startDate: start.addingTimeInterval(-60), endDate: start),
            WalkMetadata(id: unknownID, startDate: start.addingTimeInterval(-120), endDate: start)
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
        XCTAssertEqual(
            WalkRouteSummary(id: routeID, startDate: start, endDate: start.addingTimeInterval(1), hasGPSRoute: true).filename,
            route.filename
        )

        try store.delete(ids: [unknownID])
        let countAfterDeletion = try await store.fetchWalkCount()
        XCTAssertEqual(countAfterDeletion, 2)
    }

    func testLegacyRouteRowsAreReportedAsRouteAvailable() async throws {
        let route = route(start: Date(timeIntervalSince1970: 10), latitude: 1)
        let object = NSEntityDescription.insertNewObject(forEntityName: "PersistedWalk", into: store.container.viewContext) as! PersistedWalk
        object.id = route.id
        object.startDate = route.startDate
        object.endDate = route.endDate
        object.locationsData = try JSONEncoder().encode(route.locations)
        try store.container.viewContext.save()

        let page = try await store.fetchRouteSummaryPage(limit: 10)

        XCTAssertTrue(page.summaries[0].hasGPSRoute)
    }

    func testWalkSummaryFilterMatchesDateAndDurationWithoutLoadingLocations() async throws {
        let short = route(start: Date(timeIntervalSince1970: 100), latitude: 1)
        let long = WalkRoute(
            id: UUID(), startDate: Date(timeIntervalSince1970: 200),
            endDate: Date(timeIntervalSince1970: 200 + 3_600), locations: []
        )
        let outsideDate = WalkRoute(
            id: UUID(), startDate: Date(timeIntervalSince1970: 10_000),
            endDate: Date(timeIntervalSince1970: 13_600), locations: []
        )
        try store.save([short, long, outsideDate])
        let filter = WalkSearchFilter(
            startDate: Date(timeIntervalSince1970: 150),
            endDate: Date(timeIntervalSince1970: 500),
            minimumDuration: 1_800,
            maximumDuration: 5_400
        )

        let page = try await store.fetchRouteSummaryPage(limit: 10, filter: filter)

        XCTAssertEqual(page.summaries.map(\.id), [long.id])
        XCTAssertTrue(page.summaries[0].hasGPSRoute)
    }

    func testEmptySaveAndDeleteAreNoOps() async throws {
        try store.save([])
        try store.delete(ids: [])
        try await store.saveRoutes([])
        try await store.saveWorkoutMetadata([])
        let emptyBatch = try await store.fetchRoutes(ids: [])
        XCTAssertTrue(emptyBatch.isEmpty)
        XCTAssertTrue(store.fetchRoutes().isEmpty)
    }

    func testPersistentStoreDescriptionEnablesPrivateCloudKitMirroring() {
        let description = WalkStore.makePersistentStoreDescription(
            storeURL: URL(fileURLWithPath: "/tmp/WalksGPX-test.sqlite"),
            inMemory: false,
            cloudKitContainerIdentifier: ICloudExportConfiguration.containerIdentifier
        )

        XCTAssertEqual(description.url, URL(fileURLWithPath: "/tmp/WalksGPX-test.sqlite"))
        XCTAssertEqual(
            description.cloudKitContainerOptions?.containerIdentifier,
            ICloudExportConfiguration.containerIdentifier
        )
        XCTAssertTrue(description.cloudKitContainerOptions?.databaseScope == CKDatabase.Scope.private)
        XCTAssertEqual(
            (description.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber)?.boolValue,
            true
        )
        XCTAssertEqual(
            (description.options[NSPersistentHistoryTrackingKey] as? NSNumber)?.boolValue,
            true
        )
    }

    func testInMemoryStoreDoesNotAttemptCloudKitMirroring() {
        let description = WalkStore.makePersistentStoreDescription(
            storeURL: nil,
            inMemory: true,
            cloudKitContainerIdentifier: ICloudExportConfiguration.containerIdentifier
        )

        XCTAssertEqual(description.type, NSInMemoryStoreType)
        XCTAssertNil(description.cloudKitContainerOptions)
    }

    func testTestHostCanDisableCloudKitWhenItHasNoContainerEntitlement() {
        XCTAssertNil(WalkStore.resolvedCloudKitContainerIdentifier(
            configured: ICloudExportConfiguration.containerIdentifier,
            arguments: ["WalksGPX iOS", "--walksgpx-disable-cloudkit"]
        ))
        XCTAssertEqual(
            WalkStore.resolvedCloudKitContainerIdentifier(
                configured: ICloudExportConfiguration.containerIdentifier,
                arguments: ["WalksGPX iOS"],
                environment: [:]
            ),
            ICloudExportConfiguration.containerIdentifier
        )
        XCTAssertNil(WalkStore.resolvedCloudKitContainerIdentifier(
            configured: ICloudExportConfiguration.containerIdentifier,
            arguments: ["WalksGPX iOS"],
            environment: ["WALKSGPX_DISABLE_CLOUDKIT": "1"]
        ))
        XCTAssertNil(WalkStore.resolvedCloudKitContainerIdentifier(
            configured: ICloudExportConfiguration.containerIdentifier,
            arguments: ["WalksGPX iOS"],
            environment: ["XCTestConfigurationFilePath": "/tmp/WalksGPX.xctestconfiguration"]
        ))
    }

    func testCorruptStoredLocationsAreNotReturned() throws {
        let object = NSEntityDescription.insertNewObject(forEntityName: "PersistedWalk", into: store.container.viewContext) as! PersistedWalk
        object.id = UUID()
        object.startDate = Date()
        object.endDate = Date()
        object.locationsData = Data("not-json".utf8)
        try store.container.viewContext.save()

        XCTAssertTrue(store.fetchRoutes().isEmpty)
    }

    func testRouteSummaryPagesUseStableCursorOrdering() async throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let olderTimestamp = Date(timeIntervalSince1970: 50)
        let ids = [1, 2, 3].map { number in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        }
        let routes = [
            WalkRoute(id: ids[0], startDate: timestamp, endDate: timestamp.addingTimeInterval(60), locations: []),
            WalkRoute(id: ids[1], startDate: timestamp, endDate: timestamp.addingTimeInterval(60), locations: []),
            WalkRoute(id: ids[2], startDate: olderTimestamp, endDate: olderTimestamp.addingTimeInterval(60), locations: [])
        ]
        try store.save(routes)

        let firstPage = try await store.fetchRouteSummaryPage(limit: 1)
        let secondPage = try await store.fetchRouteSummaryPage(limit: 1, before: firstPage.nextCursor)
        let thirdPage = try await store.fetchRouteSummaryPage(limit: 1, before: secondPage.nextCursor)

        XCTAssertEqual(firstPage.summaries.map(\.id), [ids[0]])
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(secondPage.summaries.map(\.id), [ids[1]])
        XCTAssertTrue(secondPage.hasMore)
        XCTAssertEqual(thirdPage.summaries.map(\.id), [ids[2]])
        XCTAssertFalse(thirdPage.hasMore)
        XCTAssertNil(thirdPage.nextCursor)
    }

    func testRouteSummaryPageDoesNotDecodeLargeRoutePayload() async throws {
        let object = NSEntityDescription.insertNewObject(forEntityName: "PersistedWalk", into: store.container.viewContext) as! PersistedWalk
        object.id = UUID()
        object.startDate = Date(timeIntervalSince1970: 10)
        object.endDate = Date(timeIntervalSince1970: 70)
        object.locationsData = Data("not-json".utf8)
        try store.container.viewContext.save()

        let page = try await store.fetchRouteSummaryPage(limit: 10)

        XCTAssertEqual(page.summaries.map(\.id), [object.id])
        XCTAssertEqual(page.summaries.first?.startDate, object.startDate)
        XCTAssertFalse(page.hasMore)
    }

    func testFetchRouteLoadsOnlyRequestedRoute() async throws {
        let requested = route(start: Date(timeIntervalSince1970: 10), latitude: 1)
        let other = route(start: Date(timeIntervalSince1970: 20), latitude: 2)
        try store.save([requested, other])

        let loaded = try await store.fetchRoute(id: requested.id)

        XCTAssertEqual(loaded, requested)
    }

    func testWalkMonthIndexGroupsCountsAndOrdersByCalendarMonth() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = [
            date("2026-10-11T07:30:00Z"),
            date("2026-10-10T16:17:00Z"),
            date("2026-09-30T23:59:00Z"),
            date("2025-10-01T00:00:00Z")
        ]
        try store.save(dates.map { route(start: $0, latitude: 1) })

        let months = try await store.fetchWalkMonths(calendar: calendar)

        XCTAssertEqual(months.map(\.title), ["October 2026", "September 2026", "October 2025"])
        XCTAssertEqual(months.map(\.walkCount), [2, 1, 1])
        XCTAssertEqual(months[0].monthName, "October")
        XCTAssertEqual(months[0].endDate, date("2026-11-01T00:00:00Z"))
    }

    func testRemoteRefreshDoesNotReloadWalkPageWhenSelectedMonthIsUnchanged() {
        let selected = WalkMonth(
            startDate: date("2026-10-01T00:00:00Z"),
            endDate: date("2026-11-01T00:00:00Z"),
            walkCount: 29
        )

        XCTAssertFalse(WalkMonthReloadPolicy.shouldReloadPage(
            previousSelection: selected,
            refreshedSelection: selected,
            force: false
        ))
    }

    func testSelectedMonthChangesAndExplicitRefreshReloadWalkPage() {
        let october = WalkMonth(
            startDate: date("2026-10-01T00:00:00Z"),
            endDate: date("2026-11-01T00:00:00Z"),
            walkCount: 29
        )
        let octoberAfterNewWalk = WalkMonth(
            startDate: october.startDate,
            endDate: october.endDate,
            walkCount: 30
        )

        XCTAssertTrue(WalkMonthReloadPolicy.shouldReloadPage(
            previousSelection: october,
            refreshedSelection: octoberAfterNewWalk,
            force: false
        ))
        XCTAssertTrue(WalkMonthReloadPolicy.shouldReloadPage(
            previousSelection: october,
            refreshedSelection: october,
            force: true
        ))
        XCTAssertTrue(WalkMonthReloadPolicy.shouldReloadPage(
            previousSelection: nil,
            refreshedSelection: october,
            force: false
        ))
    }

    func testLibraryLoadsMonthSummariesAndPreservesSelectionWhenReloading() async throws {
        let older = route(start: Date(timeIntervalSince1970: 100), latitude: 1)
        let newer = route(start: Date(timeIntervalSince1970: 200), latitude: 2)
        try store.save([older, newer])
        let library = WalkLibraryModel(store: store, pageSize: 1)

        await library.refresh()
        XCTAssertEqual(library.walks.map(\.id), [newer.id])
        XCTAssertTrue(library.hasMore)
        library.selectWalk(library.walks[0])

        await library.loadNextPage()
        XCTAssertEqual(library.walks.map(\.id), [newer.id, older.id])
        await library.refresh(force: true)

        XCTAssertEqual(library.selectedWalk?.id, newer.id)
        XCTAssertEqual(library.walks.map(\.id), [newer.id])
    }

    func testLibraryReportsMonthLoadFailureAndContinuesToRepresentLoadingStateCorrectly() async {
        let source = ScriptedWalkLibraryDataSource()
        source.months = { _ in throw LibraryTestError.unavailable }
        let library = WalkLibraryModel(store: source)

        await library.refresh()

        XCTAssertEqual(library.errorMessage, "Couldn’t load walk months: The test data source is unavailable.")
        XCTAssertFalse(library.isLoading)
        XCTAssertNil(library.selectedMonth)
    }

    func testLibraryReportsFirstPageAndNextPageFailuresWithoutDiscardingExistingRows() async {
        let row = WalkRouteSummary(
            id: UUID(), startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 160), hasGPSRoute: true
        )
        let source = ScriptedWalkLibraryDataSource()
        source.page = { _, _, _, _ in throw LibraryTestError.unavailable }
        let library = WalkLibraryModel(store: source)
        await library.loadFirstPage()
        XCTAssertTrue(library.walks.isEmpty)
        XCTAssertEqual(library.errorMessage, "Couldn’t load walks: The test data source is unavailable.")

        let cursor = WalkRoutePageCursor(startDate: row.startDate, id: row.id)
        source.page = { _, before, _, _ in
            if before == nil { return WalkRouteSummaryPage(summaries: [row], nextCursor: cursor, hasMore: true) }
            throw LibraryTestError.unavailable
        }
        await library.loadFirstPage()
        XCTAssertEqual(library.walks, [row])
        await library.loadNextPage()

        XCTAssertEqual(library.walks, [row], "A failed later page must preserve already-loaded rows")
        XCTAssertFalse(library.hasMore)
        XCTAssertEqual(library.errorMessage, "Couldn’t load more walks: The test data source is unavailable.")
        XCTAssertFalse(library.isLoading)
    }

    func testLibraryAppliesArchiveFilterAndClearRestoresSelectedMonth() async {
        let month = WalkMonth(startDate: date("2026-10-01T00:00:00Z"), endDate: date("2026-11-01T00:00:00Z"), walkCount: 1)
        let source = ScriptedWalkLibraryDataSource()
        source.months = { _ in [month] }
        var requestedMonth: WalkMonth? = month
        var requestedFilter: WalkSearchFilter? = nil
        source.page = { _, _, inMonth, filter in
            requestedMonth = inMonth
            requestedFilter = filter
            return WalkRouteSummaryPage(summaries: [], nextCursor: nil, hasMore: false)
        }
        let library = WalkLibraryModel(store: source)
        await library.refresh()

        let filter = WalkSearchFilter(startDate: date("2020-01-01T00:00:00Z"), minimumDuration: 1_800)
        await library.apply(filter: filter)
        XCTAssertTrue(library.isFiltering)
        XCTAssertNil(requestedMonth, "Archive search must not be scoped to the selected month")
        XCTAssertEqual(requestedFilter, filter)

        await library.clearFilter()
        XCTAssertFalse(library.isFiltering)
        XCTAssertEqual(requestedMonth, month)
        XCTAssertNil(requestedFilter)
    }

    func testLibraryIgnoresAStalePageThatFinishesAfterANewerFilter() async {
        let staleRow = WalkRouteSummary(
            id: UUID(), startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 160), hasGPSRoute: true
        )
        let currentRow = WalkRouteSummary(
            id: UUID(), startDate: Date(timeIntervalSince1970: 200),
            endDate: Date(timeIntervalSince1970: 260), hasGPSRoute: true
        )
        let source = ScriptedWalkLibraryDataSource()
        var releaseStalePage: CheckedContinuation<WalkRouteSummaryPage, Error>?
        source.page = { _, _, _, filter in
            if filter == nil {
                return try await withCheckedThrowingContinuation { releaseStalePage = $0 }
            }
            return WalkRouteSummaryPage(summaries: [currentRow], nextCursor: nil, hasMore: false)
        }
        let library = WalkLibraryModel(store: source)
        let staleLoad = Task { await library.loadFirstPage() }
        while releaseStalePage == nil { await Task.yield() }

        await library.apply(filter: WalkSearchFilter(minimumDuration: 10))
        releaseStalePage?.resume(returning: WalkRouteSummaryPage(summaries: [staleRow], nextCursor: nil, hasMore: false))
        await staleLoad.value

        XCTAssertEqual(library.walks, [currentRow])
        XCTAssertFalse(library.isLoading)
    }

    func testWalkDetailShowsUnavailableWhenMetadataHasNoReadableRoute() async throws {
        let start = Date(timeIntervalSince1970: 500)
        let metadata = WalkMetadata(id: UUID(), startDate: start, endDate: start.addingTimeInterval(3_600))
        try await store.saveWorkoutMetadata([metadata])
        let detail = WalkDetailModel(store: store)
        let summary = WalkRouteSummary(
            id: metadata.id, startDate: metadata.startDate, endDate: metadata.endDate, hasGPSRoute: false
        )

        await detail.load(summary)

        XCTAssertEqual(detail.state, .routeUnavailable)
        do {
            _ = try await detail.exportData()
            XCTFail("A route-less workout must not export GPX.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This walk does not have a readable GPS route to export.")
        }
    }

    func testWalkDetailLoadsOneRouteAndSerializesGPXOnDemand() async throws {
        let start = Date(timeIntervalSince1970: 600)
        let walk = WalkRoute(id: UUID(), startDate: start, endDate: start.addingTimeInterval(60), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(60))
        ])
        try await store.saveRoutes([walk])
        let detail = WalkDetailModel(store: store)
        let summary = WalkRouteSummary(id: walk.id, startDate: walk.startDate, endDate: walk.endDate, hasGPSRoute: true)

        await detail.load(summary)
        let exportData = try await detail.exportData()

        XCTAssertEqual(detail.state, .ready)
        XCTAssertEqual(detail.route, walk)
        XCTAssertTrue(String(decoding: exportData, as: UTF8.self).contains("<trkseg>"))
    }

    func testWalkDetailDistinguishesMissingShortAndFailedRoutes() async throws {
        let start = Date(timeIntervalSince1970: 700)
        let missing = WalkRouteSummary(id: UUID(), startDate: start, endDate: start.addingTimeInterval(60), hasGPSRoute: true)
        try await store.saveWorkoutMetadata([WalkMetadata(id: missing.id, startDate: start, endDate: missing.endDate)])
        let missingDetail = WalkDetailModel(store: store)
        await missingDetail.load(missing)
        XCTAssertEqual(missingDetail.state, .routeUnavailable)

        let shortRoute = WalkRoute(id: UUID(), startDate: start, endDate: start.addingTimeInterval(60), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start)
        ])
        try await store.saveRoutes([shortRoute])
        let shortDetail = WalkDetailModel(store: store)
        await shortDetail.load(WalkRouteSummary(id: shortRoute.id, startDate: start, endDate: shortRoute.endDate, hasGPSRoute: true))
        XCTAssertEqual(shortDetail.state, .routeUnavailable)
        XCTAssertNil(shortDetail.route)

        let failedSource = ScriptedWalkLibraryDataSource()
        failedSource.route = { _ in throw LibraryTestError.unavailable }
        let failedDetail = WalkDetailModel(store: failedSource)
        await failedDetail.load(missing)
        XCTAssertEqual(failedDetail.state, .failed("The test data source is unavailable."))
    }

    func testWalkDetailIgnoresAnOlderRouteResultAfterSelectionChanges() async {
        let start = Date(timeIntervalSince1970: 800)
        let oldRoute = WalkRoute(id: UUID(), startDate: start, endDate: start.addingTimeInterval(60), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(60))
        ])
        let newRoute = WalkRoute(id: UUID(), startDate: start, endDate: start.addingTimeInterval(120), locations: [
            RouteLocation(latitude: 52.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 52.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(120))
        ])
        let source = ScriptedWalkLibraryDataSource()
        var releaseOldRoute: CheckedContinuation<WalkRoute?, Error>?
        source.route = { id in
            if id == oldRoute.id {
                return try await withCheckedThrowingContinuation { releaseOldRoute = $0 }
            }
            return newRoute
        }
        let detail = WalkDetailModel(store: source)
        let oldSummary = WalkRouteSummary(id: oldRoute.id, startDate: start, endDate: oldRoute.endDate, hasGPSRoute: true)
        let newSummary = WalkRouteSummary(id: newRoute.id, startDate: start, endDate: newRoute.endDate, hasGPSRoute: true)
        let oldLoad = Task { await detail.load(oldSummary) }
        while releaseOldRoute == nil { await Task.yield() }

        await detail.load(newSummary)
        releaseOldRoute?.resume(returning: oldRoute)
        await oldLoad.value

        XCTAssertEqual(detail.state, .ready)
        XCTAssertEqual(detail.route, newRoute)
    }

    func testDurationOptionsHaveExpectedBoundaries() {
        XCTAssertNil(WalkDurationFilter.any.range)
        XCTAssertEqual(WalkDurationFilter.any.title, "Any duration")
        XCTAssertEqual(WalkDurationFilter.underThirtyMinutes.range?.upperBound, 1_799)
        XCTAssertEqual(WalkDurationFilter.underThirtyMinutes.title, "Under 30 minutes")
        XCTAssertEqual(WalkDurationFilter.thirtyToSixtyMinutes.range?.lowerBound, 1_800)
        XCTAssertEqual(WalkDurationFilter.thirtyToSixtyMinutes.title, "30–60 minutes")
        XCTAssertEqual(WalkDurationFilter.oneToTwoHours.range?.lowerBound, 3_600)
        XCTAssertEqual(WalkDurationFilter.oneToTwoHours.title, "1–2 hours")
        XCTAssertEqual(WalkDurationFilter.overTwoHours.range?.lowerBound, 7_200)
        XCTAssertEqual(WalkDurationFilter.overTwoHours.title, "Over 2 hours")
    }

    func testWalkSummaryPageIsScopedToSelectedMonth() async throws {
        let october = route(start: date("2026-10-11T07:30:00Z"), latitude: 1)
        let september = route(start: date("2026-09-30T23:59:00Z"), latitude: 2)
        try store.save([october, september])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let months = try await store.fetchWalkMonths(calendar: calendar)

        let page = try await store.fetchRouteSummaryPage(limit: 10, in: months[0])

        XCTAssertEqual(page.summaries.map(\.id), [october.id])
        XCTAssertFalse(page.hasMore)
    }

    private func route(start: Date, latitude: Double) -> WalkRoute {
        WalkRoute(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(60),
            locations: [RouteLocation(latitude: latitude, longitude: 0, elevation: nil, timestamp: start)]
        )
    }

    private func date(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }
}

@MainActor
private final class ScriptedWalkLibraryDataSource: WalkLibraryDataSource {
    var months: (Calendar) async throws -> [WalkMonth] = { _ in [] }
    var page: (Int, WalkRoutePageCursor?, WalkMonth?, WalkSearchFilter?) async throws -> WalkRouteSummaryPage = { _, _, _, _ in
        WalkRouteSummaryPage(summaries: [], nextCursor: nil, hasMore: false)
    }
    var route: (UUID) async throws -> WalkRoute? = { _ in nil }

    func waitUntilReady() async {}
    func fetchWalkMonths(calendar: Calendar) async throws -> [WalkMonth] { try await months(calendar) }
    func fetchRouteSummaryPage(
        limit: Int,
        before cursor: WalkRoutePageCursor?,
        in month: WalkMonth?,
        filter: WalkSearchFilter?
    ) async throws -> WalkRouteSummaryPage {
        try await page(limit, cursor, month, filter)
    }
    func fetchRoute(id: UUID) async throws -> WalkRoute? { try await route(id) }
}

private enum LibraryTestError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The test data source is unavailable." }
}
