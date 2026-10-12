import SwiftUI
import UIKit
import HealthKit
import XCTest
@testable import WalksGPX_iOS

@MainActor
final class ContentViewTests: XCTestCase {
    private var hostingWindows: [UIWindow] = []

    override func tearDown() async throws {
        hostingWindows.forEach { $0.isHidden = true }
        hostingWindows.removeAll()
        try await super.tearDown()
    }

    func testRootViewRendersLoadingEmptySavedAndICloudRetryStates() async {
        let states = [
            HealthKitPresentationState(isLoading: true, totalWalks: 10),
            HealthKitPresentationState(syncMessage: "No walks"),
            HealthKitPresentationState(isLoading: true, processedWalks: 2, totalWalks: 4, savedWalkCount: 1, savedRouteCount: 1),
            HealthKitPresentationState(iCloudExportMessage: "iCloud export needs a retry", savedWalkCount: 1, savedRouteCount: 1)
        ]

        for state in states {
            let store = WalkStore(inMemory: true)
            await store.waitUntilReady()
            let service = HealthKitService(
                presentationState: state,
                iCloudReconciliationOverride: {},
                walkStore: store
            )
            let controller = await render(ContentView(healthKit: service, library: WalkLibraryModel(store: store)))

            XCTAssertNotNil(controller.view)
            XCTAssertGreaterThan(controller.view.bounds.width, 0)
        }
    }

    func testSyncActivitySheetRendersCheckingProgressReadyAndErrorStates() async {
        let states = [
            HealthKitPresentationState(isLoading: true, hasConnected: true),
            HealthKitPresentationState(isLoading: true, processedWalks: 2, totalWalks: 4, pendingRouteCount: 1, syncMessage: "Reading walks", savedWalkCount: 7, savedRouteCount: 6),
            HealthKitPresentationState(pendingRouteCount: 1, hasConnected: true, iCloudExportMessage: "Prepared routes", savedWalkCount: 10, savedRouteCount: 9),
            HealthKitPresentationState(errorMessage: "Health access denied", iCloudExportMessage: "iCloud export needs a retry")
        ]

        for state in states {
            let service = HealthKitService(presentationState: state)
            let controller = await render(SyncActivitySheet(healthKit: service))
            XCTAssertGreaterThan(controller.view.bounds.width, 0)
        }
    }

    func testFilterSheetRendersDateEnabledAndDurationOnlyConfigurations() async {
        let dateFilter = WalkSearchFilter(
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_000_000),
            minimumDuration: 1_800,
            maximumDuration: 3_599
        )
        let dateController = await render(WalkLibraryFilterSheet(filter: dateFilter) { _ in })
        let durationController = await render(WalkLibraryFilterSheet(filter: WalkSearchFilter(minimumDuration: 7_200)) { _ in })
        XCTAssertGreaterThan(dateController.view.bounds.width, 0)
        XCTAssertGreaterThan(durationController.view.bounds.height, 0)
    }

    func testRootViewRendersPagedArchiveWithRouteReadyAndRouteUnavailableRows() async throws {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let summaries = [
            WalkRouteSummary(id: UUID(), startDate: start, endDate: start.addingTimeInterval(3_600), hasGPSRoute: true),
            WalkRouteSummary(id: UUID(), startDate: start.addingTimeInterval(-86_400), endDate: start.addingTimeInterval(-82_800), hasGPSRoute: false),
            WalkRouteSummary(id: UUID(), startDate: start.addingTimeInterval(-172_800), endDate: start.addingTimeInterval(-169_200), hasGPSRoute: false)
        ]
        let library = WalkLibraryModel(store: StaticWalkLibraryDataSource(summaries: summaries))
        await library.refresh(force: true)
        let service = HealthKitService(
            presentationState: HealthKitPresentationState(savedWalkCount: 3, savedRouteCount: 1),
            iCloudReconciliationOverride: {},
            walkStore: store
        )

        let content = ContentView(healthKit: service, library: library)
        let controller = await render(content)

        XCTAssertEqual(library.walks.count, summaries.count)
        XCTAssertEqual(content.currentSummary(for: summaries[0].id), summaries[0])
        XCTAssertNil(content.currentSummary(for: UUID()))
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
    }

    func testLibraryCreatesDetailModelAndLoadsRouteOnlyByExplicitRequest() async throws {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = WalkRoute(id: UUID(), startDate: start, endDate: start.addingTimeInterval(60), locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: start),
            RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(60))
        ])
        try await store.saveRoutes([route])
        let library = WalkLibraryModel(store: store)
        await library.refresh(force: true)

        XCTAssertEqual(library.walks.map(\.id), [route.id])
        let detailModel = library.makeDetailModel()
        let loadedRoute = try await library.loadRoute(id: route.id)
        XCTAssertEqual(loadedRoute, route)
        await detailModel.load(try XCTUnwrap(library.walks.first))
        XCTAssertEqual(detailModel.route, route)
        XCTAssertEqual(detailModel.state, .ready)
    }

    func testFilterBuilderCombinesOptionalDatesAndDurationRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3 * 86_400)

        let withDates = WalkLibraryFilterSheet.makeFilter(
            filtersByDate: true,
            startDate: start,
            endDate: end,
            duration: .thirtyToSixtyMinutes,
            calendar: calendar
        )
        XCTAssertEqual(withDates.startDate, calendar.startOfDay(for: start))
        XCTAssertEqual(withDates.endDate, calendar.startOfDay(for: end).addingTimeInterval(86_400))
        XCTAssertEqual(withDates.minimumDuration, 1_800)
        XCTAssertEqual(withDates.maximumDuration, 3_599)

        let durationOnly = WalkLibraryFilterSheet.makeFilter(
            filtersByDate: false,
            startDate: start,
            endDate: end,
            duration: .overTwoHours,
            calendar: calendar
        )
        XCTAssertNil(durationOnly.startDate)
        XCTAssertNil(durationOnly.endDate)
        XCTAssertEqual(durationOnly.minimumDuration, 7_200)
        XCTAssertEqual(durationOnly.maximumDuration, Double.greatestFiniteMagnitude)
    }

    @available(iOS, deprecated: 17.0)
    func testSyncHealthRefreshesTheLibraryAfterHealthKitCompletes() async {
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        let state = SyncStateStore(defaults: UserDefaults(suiteName: "ContentViewSync-\(UUID())")!)
        state.markFullHistoryBackfillComplete()
        state.markWorkoutMetadataBackfillComplete()
        let healthKit = HealthKitService(
            syncState: state,
            queryOverrides: HealthKitQueryOverrides(
                workoutChanges: { (added: [], deleted: [], anchor: HKQueryAnchor(fromValue: 77)) },
                pendingWorkouts: { [] },
                allWalkingWorkouts: { [] },
                route: { _ in nil }
            ),
            iCloudReconciliationOverride: {},
            walkStore: store
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = WalkRouteSummary(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(60), hasGPSRoute: false
        )
        let library = WalkLibraryModel(store: StaticWalkLibraryDataSource(summaries: [summary]))
        let content = ContentView(healthKit: healthKit, library: library)

        await content.syncHealth()

        XCTAssertEqual(state.anchor, HKQueryAnchor(fromValue: 77))
        XCTAssertEqual(library.walks, [summary])
        XCTAssertEqual(healthKit.savedWalkCount, 0)
    }

    func testPresentationStateCalculatesProgressAndRetainsUserFacingErrors() {
        let service = HealthKitService(presentationState: HealthKitPresentationState(
            processedWalks: 3,
            totalWalks: 4,
            errorMessage: "Health access was denied.",
            iCloudExportCompletedRouteCount: 1,
            iCloudExportTotalRouteCount: 2
        ))

        XCTAssertEqual(service.progress, 0.75)
        XCTAssertEqual(service.iCloudExportProgress, 0.5)
        XCTAssertEqual(service.errorMessage, "Health access was denied.")
        XCTAssertNil(HealthKitService(presentationState: HealthKitPresentationState()).iCloudExportProgress)
        XCTAssertEqual(SyncError.missingAnchor.errorDescription, "HealthKit did not return a sync anchor.")
    }

    func testReusableWalkViewsRenderRouteAndNoRouteStates() async throws {
        let route = WalkRoute(
            id: UUID(), startDate: .now.addingTimeInterval(-60), endDate: .now,
            locations: [
                RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: .now.addingTimeInterval(-60)),
                RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: .now)
            ]
        )
        let noRoute = WalkRoute(id: UUID(), startDate: .now, endDate: .now, locations: [])
        let store = WalkStore(inMemory: true)
        await store.waitUntilReady()
        try await store.saveRoutes([route])
        let readyDetailModel = WalkDetailModel(store: store)
        let readySummary = WalkRouteSummary(id: route.id, startDate: route.startDate, endDate: route.endDate, hasGPSRoute: true)
        await readyDetailModel.load(readySummary)
        let unavailableSummary = WalkRouteSummary(id: noRoute.id, startDate: noRoute.startDate, endDate: noRoute.endDate, hasGPSRoute: false)
        let unavailableDetailModel = WalkDetailModel(store: store)
        await unavailableDetailModel.load(unavailableSummary)
        let failedDetailModel = WalkDetailModel(store: FailingWalkLibraryDataSource())
        await failedDetailModel.load(readySummary)
        XCTAssertEqual(readyDetailModel.state, .ready)
        XCTAssertEqual(unavailableDetailModel.state, .routeUnavailable)
        XCTAssertEqual(failedDetailModel.state, .failed("The test route load failed."))

        for view in [
            AnyView(WalkingAnimationView()),
            AnyView(WalkRouteMap(route: route)),
            AnyView(WalkLibraryRow(
                summary: WalkRouteSummary(id: route.id, startDate: route.startDate, endDate: route.endDate, hasGPSRoute: true),
                action: {}
            )),
            AnyView(WalkLibraryRow(
                summary: WalkRouteSummary(id: noRoute.id, startDate: noRoute.startDate, endDate: noRoute.endDate, hasGPSRoute: false),
                action: {}
            )),
            AnyView(WalkDetailScreen(summary: readySummary, model: readyDetailModel)),
            AnyView(WalkDetailScreen(summary: unavailableSummary, model: unavailableDetailModel)),
            AnyView(WalkDetailScreen(summary: readySummary, model: failedDetailModel))
        ] {
            let controller = await render(view)
            XCTAssertNotNil(controller.view)
        }

    }

    private func render<Content: View>(_ content: Content) async -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        hostingWindows.append(window)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()
        return controller
    }

}

@MainActor
private final class FailingWalkLibraryDataSource: WalkLibraryDataSource {
    func waitUntilReady() async {}
    func fetchWalkMonths(calendar: Calendar) async throws -> [WalkMonth] { [] }
    func fetchRouteSummaryPage(
        limit: Int,
        before cursor: WalkRoutePageCursor?,
        in month: WalkMonth?,
        filter: WalkSearchFilter?
    ) async throws -> WalkRouteSummaryPage {
        WalkRouteSummaryPage(summaries: [], nextCursor: nil, hasMore: false)
    }
    func fetchRoute(id: UUID) async throws -> WalkRoute? {
        throw NSError(domain: "WalkDetailTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The test route load failed."])
    }
}

@MainActor
private final class StaticWalkLibraryDataSource: WalkLibraryDataSource {
    let summaries: [WalkRouteSummary]

    init(summaries: [WalkRouteSummary]) { self.summaries = summaries }
    func waitUntilReady() async {}
    func fetchWalkMonths(calendar: Calendar) async throws -> [WalkMonth] {
        WalkMonth.group(startDates: summaries.map(\.startDate), calendar: calendar)
    }
    func fetchRouteSummaryPage(
        limit: Int,
        before cursor: WalkRoutePageCursor?,
        in month: WalkMonth?,
        filter: WalkSearchFilter?
    ) async throws -> WalkRouteSummaryPage {
        let matching = summaries.filter { summary in
            (month.map { summary.startDate >= $0.startDate && summary.startDate < $0.endDate } ?? true)
                && (filter?.matches(summary) ?? true)
        }
        let page = Array(matching.prefix(limit))
        return WalkRouteSummaryPage(summaries: page, nextCursor: nil, hasMore: false)
    }
    func fetchRoute(id: UUID) async throws -> WalkRoute? { nil }
}
