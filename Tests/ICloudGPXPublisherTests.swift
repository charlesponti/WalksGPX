import XCTest
@testable import WalksGPX_iOS

final class ICloudGPXPublisherTests: XCTestCase {
    private var folderURL: URL!
    private var publisher: ICloudGPXPublisher!

    override func setUpWithError() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalksGPXPublisherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let folder = folderURL!
        publisher = ICloudGPXPublisher(exportFolderProvider: { folder })
    }

    override func tearDownWithError() throws {
        if let folderURL {
            try? FileManager.default.removeItem(at: folderURL)
        }
        publisher = nil
        folderURL = nil
    }

    func testPublishBatchWritesGPXAndManifestThenUpdatesExistingRoute() async throws {
        let first = route(start: 10, latitude: 51.5)
        let second = route(start: 20, latitude: 51.6)

        let firstReport = try await publisher.publishBatch([first, second])

        XCTAssertEqual(firstReport.routeCount, 2)
        XCTAssertFalse(firstReport.allFilesUploaded)
        XCTAssertEqual(firstReport.folderURL, folderURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(for: first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(for: second).path))
        let initialManifest = try manifest()
        XCTAssertEqual(initialManifest.walks.map(\.id), [first.id, second.id])

        let revisedFirst = WalkRoute(
            id: first.id, startDate: first.startDate, endDate: first.endDate,
            locations: first.locations + [RouteLocation(latitude: 51.51, longitude: -0.1, elevation: nil, timestamp: first.endDate)]
        )
        let secondReport = try await publisher.publishBatch([revisedFirst])

        XCTAssertEqual(secondReport.routeCount, 2)
        let revisedManifest = try manifest()
        XCTAssertEqual(revisedManifest.walks.count, 2)
        XCTAssertEqual(revisedManifest.walks.first(where: { $0.id == first.id })?.pointCount, 2)
        let firstGPX = try String(contentsOf: fileURL(for: first), encoding: .utf8)
        XCTAssertEqual(firstGPX.components(separatedBy: "<trkpt ").count - 1, 2)
    }

    func testReconcileDeduplicatesReportsBatchProgressAndRemovesStaleFiles() async throws {
        let stale = route(start: 1, latitude: 1)
        _ = try await publisher.publishBatch([stale])
        let routes = (0...100).map { index in route(start: TimeInterval(index + 10), latitude: Double(index % 80)) }
        let duplicate = WalkRoute(
            id: routes[0].id, startDate: routes[0].startDate, endDate: routes[0].endDate,
            locations: routes[0].locations + [RouteLocation(latitude: 1, longitude: 1, elevation: nil, timestamp: routes[0].endDate)]
        )
        let updates = ProgressRecorder()

        let report = try await publisher.reconcile(routes: routes + [duplicate]) { updates.append($0) }

        XCTAssertEqual(report.routeCount, 101)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(for: stale).path))
        XCTAssertEqual(try manifest().walks.count, 101)
        XCTAssertEqual(updates.values, [
            ICloudExportProgress(completedRoutes: 100, totalRoutes: 101),
            ICloudExportProgress(completedRoutes: 101, totalRoutes: 101),
            ICloudExportProgress(completedRoutes: 101, totalRoutes: 101)
        ])
        let duplicatedGPX = try String(contentsOf: fileURL(for: duplicate), encoding: .utf8)
        XCTAssertEqual(duplicatedGPX.components(separatedBy: "<trkpt ").count - 1, 2)
    }

    func testReconcileRecoversFromMalformedManifestAndIgnoresUnrelatedFiles() async throws {
        let route = route(start: 10, latitude: 51.5)
        try Data("not-json".utf8).write(to: manifestURL)
        let unrelated = folderURL.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelated)

        _ = try await publisher.reconcile(routes: [route])

        XCTAssertEqual(try manifest().walks.map(\.id), [route.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testReconcileRejectsUnknownManifestSchemaWithoutDeletingFiles() async throws {
        let route = route(start: 10, latitude: 51.5)
        let oldGPX = folderURL.appendingPathComponent("walk-old.gpx")
        try Data("old".utf8).write(to: oldGPX)
        try Data("{\"schemaVersion\":2,\"generatedAt\":\"2023-11-14T22:13:20Z\",\"walks\":[]}".utf8).write(to: manifestURL)

        do {
            _ = try await publisher.reconcile(routes: [route])
            XCTFail("Expected an unsupported schema error")
        } catch let error as ICloudExportManifestError {
            XCTAssertEqual(error, .unsupportedSchema(2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldGPX.path))
    }

    func testDefaultPublisherExplainsWhenICloudContainerIsUnavailable() async {
        let publisher = ICloudGPXPublisher()

        do {
            _ = try await publisher.publishBatch([])
            XCTFail("The simulator should not provide this app's iCloud container")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "iCloud Drive is unavailable. Check that you’re signed in and iCloud Drive is enabled; saved walks remain on this iPhone and will retry."
            )
        }
    }

    func testEmptyReconciliationRemovesOnlyGeneratedFiles() async throws {
        let staleGPX = folderURL.appendingPathComponent("walk-stale.gpx")
        let unrelated = folderURL.appendingPathComponent("readme.txt")
        try Data("stale".utf8).write(to: staleGPX)
        try Data("keep".utf8).write(to: unrelated)

        let report = try await publisher.reconcile(routes: [])

        XCTAssertEqual(report.routeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleGPX.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    private var manifestURL: URL {
        folderURL.appendingPathComponent(ICloudExportConfiguration.manifestFilename)
    }

    private func manifest() throws -> ICloudExportManifest {
        try ICloudExportManifest.decode(Data(contentsOf: manifestURL))
    }

    private func fileURL(for route: WalkRoute) -> URL {
        folderURL.appendingPathComponent(ICloudExportManifestEntry.filename(for: route.id))
    }

    private func route(start: TimeInterval, latitude: Double) -> WalkRoute {
        let date = Date(timeIntervalSince1970: start)
        return WalkRoute(
            id: UUID(), startDate: date, endDate: date.addingTimeInterval(60),
            locations: [RouteLocation(latitude: latitude, longitude: -0.1, elevation: nil, timestamp: date)]
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ICloudExportProgress] = []

    func append(_ progress: ICloudExportProgress) {
        lock.withLock { storage.append(progress) }
    }

    var values: [ICloudExportProgress] {
        lock.withLock { storage }
    }
}
