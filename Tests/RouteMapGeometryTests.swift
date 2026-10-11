import MapKit
import XCTest
@testable import WalksGPX_iOS

final class RouteMapGeometryTests: XCTestCase {
    func testCoordinatesDiscardInvalidRoutePoints() {
        let route = WalkRoute(id: UUID(), startDate: .now, endDate: .now, locations: [
            RouteLocation(latitude: 51.5, longitude: -0.12, elevation: nil, timestamp: .now),
            RouteLocation(latitude: 91, longitude: 0, elevation: nil, timestamp: .now)
        ])

        XCTAssertEqual(RouteMapGeometry.coordinates(for: route).map(\.latitude), [51.5])
    }

    func testRegionProvidesStableFallbackAndMinimumSpan() {
        let fallback = RouteMapGeometry.region(for: [])
        XCTAssertEqual(fallback.center.latitude, 0)
        XCTAssertEqual(fallback.span.latitudeDelta, 1)

        let point = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        let region = RouteMapGeometry.region(for: [point])
        XCTAssertEqual(region.center.latitude, 51.5)
        XCTAssertEqual(region.span.latitudeDelta, 0.002)
        XCTAssertEqual(region.span.longitudeDelta, 0.002)
    }

    func testRegionUsesShortSpanAcrossInternationalDateLine() {
        let region = RouteMapGeometry.region(for: [
            CLLocationCoordinate2D(latitude: 10, longitude: 179.8),
            CLLocationCoordinate2D(latitude: 11, longitude: -179.8)
        ])

        XCTAssertEqual(region.center.latitude, 10.5)
        XCTAssertEqual(abs(region.center.longitude), 180, accuracy: 0.001)
        XCTAssertLessThan(region.span.longitudeDelta, 1)
    }
}
