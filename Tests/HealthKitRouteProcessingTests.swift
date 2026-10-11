import CoreLocation
import XCTest
@testable import WalksGPX_iOS

final class HealthKitRouteProcessingTests: XCTestCase {
    func testAccumulatorCompletesOnlyAfterEveryRouteAndSortsLocations() {
        let accumulator = RouteBatchAccumulator(routeCount: 2)
        let later = location(latitude: 2, timestamp: 20)
        let earlier = location(latitude: 1, timestamp: 10)

        assertPending(accumulator.receive(locations: [later], done: false, error: nil))
        assertPending(accumulator.receive(locations: nil, done: true, error: nil))
        let update = accumulator.receive(locations: [earlier], done: true, error: nil)

        guard case let .completed(locations) = update else {
            return XCTFail("Expected completed route batch")
        }
        XCTAssertEqual(locations.map(\.coordinate.latitude), [1, 2])
        assertIgnored(accumulator.receive(locations: [], done: true, error: nil))
    }

    func testAccumulatorFailsOnceAndIgnoresSubsequentResults() {
        let accumulator = RouteBatchAccumulator(routeCount: 1)
        let error = TestError.failed

        guard case let .failed(received as TestError) = accumulator.receive(locations: nil, done: false, error: error) else {
            return XCTFail("Expected original failure")
        }
        XCTAssertEqual(received, error)
        assertIgnored(accumulator.receive(locations: [], done: true, error: nil))
    }

    func testLocationConverterFiltersInvalidCoordinatesAndPreservesFiniteAltitude() {
        let start = Date(timeIntervalSince1970: 10)
        let points = RouteLocationConverter.points(from: [
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12), altitude: 15, horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: start),
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 100, longitude: 0), altitude: 2, horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: start),
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.6, longitude: -0.13), altitude: .infinity, horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: start)
        ])

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].elevation, 15)
        XCTAssertNil(points[1].elevation)
    }

    private func location(latitude: CLLocationDegrees, timestamp: TimeInterval) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 0),
            altitude: 0, horizontalAccuracy: 1, verticalAccuracy: 1,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func assertPending(_ update: RouteBatchAccumulator.Update, file: StaticString = #filePath, line: UInt = #line) {
        guard case .pending = update else { return XCTFail("Expected pending update", file: file, line: line) }
    }

    private func assertIgnored(_ update: RouteBatchAccumulator.Update, file: StaticString = #filePath, line: UInt = #line) {
        guard case .ignored = update else { return XCTFail("Expected ignored update", file: file, line: line) }
    }
}

private enum TestError: Error, Equatable {
    case failed
}
