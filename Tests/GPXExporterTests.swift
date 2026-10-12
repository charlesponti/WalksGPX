import XCTest
#if os(iOS)
@testable import WalksGPX_iOS
#else
@testable import WalksGPX_macOS
#endif

final class GPXExporterTests: XCTestCase {
    func testExportIncludesMetadataTrackPointsAndFiniteElevation() {
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let route = WalkRoute(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(60),
            locations: [
                RouteLocation(latitude: 51.5, longitude: -0.12, elevation: 30.5, timestamp: start),
                RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(30))
            ]
        )

        let xml = String(decoding: GPXExporter.data(for: route), as: UTF8.self)

        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<metadata><time>2023-11-14T22:13:20.125Z</time></metadata>"))
        XCTAssertTrue(xml.contains("<trkpt lat=\"51.5\" lon=\"-0.12\"><ele>30.5</ele>"))
        XCTAssertEqual(xml.components(separatedBy: "<trkpt ").count - 1, 2)
        XCTAssertTrue(xml.hasSuffix("</gpx>\n"))
    }

    func testExportOmitsInvalidCoordinatesAndNonFiniteElevation() {
        let start = Date(timeIntervalSince1970: 0)
        let route = WalkRoute(
            id: UUID(), startDate: start, endDate: start,
            locations: [
                RouteLocation(latitude: .nan, longitude: 0, elevation: nil, timestamp: start),
                RouteLocation(latitude: 91, longitude: 0, elevation: nil, timestamp: start),
                RouteLocation(latitude: 50, longitude: -1, elevation: .infinity, timestamp: start)
            ]
        )

        let xml = String(decoding: GPXExporter.data(for: route), as: UTF8.self)

        XCTAssertEqual(xml.components(separatedBy: "<trkpt ").count - 1, 1)
        XCTAssertFalse(xml.localizedCaseInsensitiveContains("nan"))
        XCTAssertFalse(xml.localizedCaseInsensitiveContains("inf"))
        XCTAssertFalse(xml.contains("<ele>"))
    }

    func testRouteDurationFilenameAndCoordinateValidation() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = WalkRoute(id: UUID(), startDate: start, endDate: start.addingTimeInterval(119.9), locations: [])

        XCTAssertEqual(route.duration, "1 min")
        XCTAssertEqual(route.filename, "walk-2023-11-14-2213.gpx")
        XCTAssertTrue(RouteLocation(latitude: -90, longitude: 180, elevation: nil, timestamp: start).isValidGPXPoint)
        XCTAssertFalse(RouteLocation(latitude: -90.001, longitude: 0, elevation: nil, timestamp: start).isValidGPXPoint)
        XCTAssertFalse(RouteLocation(latitude: 0, longitude: .infinity, elevation: nil, timestamp: start).isValidGPXPoint)
    }

    func testGPXFileDeclaresATransferRepresentation() {
        let representation = GPXFile.transferRepresentation

        withExtendedLifetime(representation) {}
    }
}
