import XCTest
#if os(iOS)
@testable import WalksGPX_iOS
#else
@testable import WalksGPX_macOS
#endif

final class ICloudExportManifestTests: XCTestCase {
    func testManifestSortsWalksByStartDateAndUsesStableUUIDFilenames() {
        let laterID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let sameDateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000.125)
        let routes = [
            makeRoute(id: laterID, start: sameDate),
            makeRoute(id: earlierID, start: sameDate.addingTimeInterval(-60)),
            makeRoute(id: sameDateID, start: sameDate)
        ]

        let manifest = ICloudExportManifest(routes: routes, generatedAt: sameDate)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.walks.map(\.id), [earlierID, sameDateID, laterID])
        XCTAssertEqual(
            manifest.walks.map(\.filename),
            [
                "walk-00000000-0000-0000-0000-000000000001.gpx",
                "walk-00000000-0000-0000-0000-000000000002.gpx",
                "walk-ffffffff-0000-0000-0000-000000000000.gpx"
            ]
        )
    }

    func testManifestDeDuplicatesRoutesByWorkoutUUID() {
        let id = UUID()
        let original = makeRoute(id: id, start: Date(timeIntervalSince1970: 1_700_000_000))
        let revised = WalkRoute(
            id: id,
            startDate: original.startDate,
            endDate: original.endDate,
            locations: original.locations + [RouteLocation(latitude: 52, longitude: 0, elevation: nil, timestamp: original.endDate)]
        )

        let manifest = ICloudExportManifest(routes: [original, revised])

        XCTAssertEqual(manifest.walks.count, 1)
        XCTAssertEqual(manifest.walks.first?.pointCount, revised.locations.count)
    }

    func testManifestRoundTripsFractionalISO8601Dates() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000.123)
        let route = makeRoute(id: UUID(), start: start)
        let manifest = ICloudExportManifest(routes: [route], generatedAt: start)

        let data = try ICloudExportManifest.encode(manifest)
        let decoded = try ICloudExportManifest.decode(data)

        XCTAssertEqual(decoded, manifest)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("2023-11-14T22:13:20.123Z"))
    }

    func testManifestDecoderRejectsUnknownSchemaVersion() throws {
        let data = Data("""
        {"schemaVersion":2,"generatedAt":"2023-11-14T22:13:20Z","walks":[]}
        """.utf8)

        XCTAssertThrowsError(try ICloudExportManifest.decode(data)) { error in
            XCTAssertEqual(error as? ICloudExportManifestError, .unsupportedSchema(2))
        }
    }

    func testManifestDecoderRejectsInvalidTimestampAndExplainsUnsupportedSchema() throws {
        let invalidDate = Data("""
        {"schemaVersion":1,"generatedAt":"not-a-date","walks":[]}
        """.utf8)

        XCTAssertThrowsError(try ICloudExportManifest.decode(invalidDate))
        XCTAssertEqual(
            ICloudExportManifestError.unsupportedSchema(2).errorDescription,
            "The iCloud export manifest uses unsupported schema version 2."
        )
    }

    func testEmptyManifestIsValid() throws {
        let manifest = ICloudExportManifest(routes: [], generatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(try ICloudExportManifest.decode(ICloudExportManifest.encode(manifest)), manifest)
        XCTAssertTrue(manifest.walks.isEmpty)
    }

    private func makeRoute(id: UUID, start: Date) -> WalkRoute {
        WalkRoute(
            id: id,
            startDate: start,
            endDate: start.addingTimeInterval(60),
            locations: [
                RouteLocation(latitude: 51.5, longitude: -0.12, elevation: 10, timestamp: start),
                RouteLocation(latitude: 51.501, longitude: -0.121, elevation: nil, timestamp: start.addingTimeInterval(30))
            ]
        )
    }
}
