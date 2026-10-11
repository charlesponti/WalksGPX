import SwiftUI
import UIKit
import XCTest
@testable import WalksGPX_iOS

@MainActor
final class ContentViewTests: XCTestCase {
    func testRootViewRendersLoadingEmptySavedAndICloudRetryStates() {
        let route = WalkRoute(
            id: UUID(), startDate: .now.addingTimeInterval(-60), endDate: .now,
            locations: [
                RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: .now.addingTimeInterval(-60)),
                RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: .now)
            ]
        )
        let states = [
            HealthKitPresentationState(isLoading: true, totalWalks: 10),
            HealthKitPresentationState(syncMessage: "No walks"),
            HealthKitPresentationState(walks: [route], isLoading: true, processedWalks: 2, totalWalks: 4),
            HealthKitPresentationState(walks: [route], iCloudExportMessage: "iCloud export needs a retry")
        ]

        for state in states {
            let service = HealthKitService(presentationState: state)
            let controller = UIHostingController(rootView: ContentView(healthKit: service))
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            controller.view.layoutIfNeeded()

            XCTAssertNotNil(controller.view)
            XCTAssertGreaterThan(controller.view.bounds.width, 0)
        }
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

    func testReusableWalkViewsRenderRouteAndNoRouteStates() {
        let route = WalkRoute(
            id: UUID(), startDate: .now.addingTimeInterval(-60), endDate: .now,
            locations: [
                RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: .now.addingTimeInterval(-60)),
                RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: .now)
            ]
        )
        let noRoute = WalkRoute(id: UUID(), startDate: .now, endDate: .now, locations: [])

        [
            AnyView(WalkingAnimationView()),
            AnyView(WalkMapPreview(walk: route)),
            AnyView(WalkMapPreview(walk: noRoute)),
            AnyView(WalkCard(walk: route))
        ].forEach { view in
            let controller = UIHostingController(rootView: view)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
            controller.view.layoutIfNeeded()
            XCTAssertNotNil(controller.view)
        }

        let animationBody = WalkingAnimationView().body
        let mapBody = WalkMapPreview(walk: route).body
        let fallbackMapBody = WalkMapPreview(walk: noRoute).body
        let cardBody = WalkCard(walk: route).body
        withExtendedLifetime((animationBody, mapBody, fallbackMapBody, cardBody)) {}
    }
}
