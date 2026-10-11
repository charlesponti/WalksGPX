import Foundation

struct ICloudExportReport: Equatable, Sendable {
    let routeCount: Int
    let allFilesUploaded: Bool
    let folderURL: URL
}

struct ICloudExportProgress: Equatable, Sendable {
    let completedRoutes: Int
    let totalRoutes: Int

    var fraction: Double {
        guard totalRoutes > 0 else { return 0 }
        return min(1, max(0, Double(completedRoutes) / Double(totalRoutes)))
    }
}

final class ICloudGPXPublisher: @unchecked Sendable {
    static let shared = ICloudGPXPublisher()

    static let publicationBatchSize = 100

    private let queue = DispatchQueue(label: "io.ponti.walksgpx.icloud-export", qos: .utility)
    private let exportFolderProvider: @Sendable () throws -> URL

    init(exportFolderProvider: @escaping @Sendable () throws -> URL = ICloudGPXPublisher.exportFolderURL) {
        self.exportFolderProvider = exportFolderProvider
    }

    func publishBatch(_ routes: [WalkRoute]) async throws -> ICloudExportReport {
        try await enqueue {
            try self.publishBatchSynchronously(routes)
        }
    }

    func reconcile(
        routes: [WalkRoute],
        progress: @escaping @Sendable (ICloudExportProgress) -> Void = { _ in }
    ) async throws -> ICloudExportReport {
        try await enqueue {
            try self.reconcileSynchronously(routes, progress: progress)
        }
    }

    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func reconcileSynchronously(
        _ routes: [WalkRoute],
        progress: @escaping @Sendable (ICloudExportProgress) -> Void
    ) throws -> ICloudExportReport {
        let uniqueRoutes = Dictionary(routes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            .values
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.id.uuidString < $1.id.uuidString
            }

        for start in stride(from: 0, to: uniqueRoutes.count, by: Self.publicationBatchSize) {
            let end = min(start + Self.publicationBatchSize, uniqueRoutes.count)
            _ = try publishBatchSynchronously(Array(uniqueRoutes[start..<end]))
            progress(ICloudExportProgress(completedRoutes: end, totalRoutes: uniqueRoutes.count))
        }

        let folderURL = try exportFolderProvider()
        let previousManifest = try Self.readManifest(in: folderURL)
        let desiredManifest = ICloudExportManifest(routes: uniqueRoutes)
        if previousManifest?.walks != desiredManifest.walks {
            try Self.writeManifest(desiredManifest, in: folderURL)
        }

        let desiredFilenames = Set(desiredManifest.walks.map(\.filename))
        for fileURL in try Self.generatedGPXFiles(in: folderURL) where !desiredFilenames.contains(fileURL.lastPathComponent) {
            try Self.removeCoordinatedItem(at: fileURL)
        }

        progress(ICloudExportProgress(completedRoutes: uniqueRoutes.count, totalRoutes: uniqueRoutes.count))
        return try Self.report(for: desiredManifest, in: folderURL)
    }

    private func publishBatchSynchronously(_ routes: [WalkRoute]) throws -> ICloudExportReport {
        let folderURL = try exportFolderProvider()
        let existingManifest = try Self.readManifest(in: folderURL)
        var entriesByID = Dictionary(existingManifest?.walks.map { ($0.id, $0) } ?? [], uniquingKeysWith: { _, latest in latest })

        for route in routes {
            let entry = ICloudExportManifestEntry(route: route)
            let fileURL = folderURL.appendingPathComponent(entry.filename, isDirectory: false)
            if entriesByID[route.id] != entry || !FileManager.default.fileExists(atPath: fileURL.path) {
                try Self.writeCoordinated(GPXExporter.data(for: route), to: fileURL)
            }
            entriesByID[route.id] = entry
        }

        let manifest = ICloudExportManifest(entries: Array(entriesByID.values))
        if existingManifest?.walks != manifest.walks {
            try Self.writeManifest(manifest, in: folderURL)
        }
        return ICloudExportReport(routeCount: manifest.walks.count, allFilesUploaded: false, folderURL: folderURL)
    }

    private static func exportFolderURL() throws -> URL {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: ICloudExportConfiguration.containerIdentifier) else {
            throw ICloudGPXPublisherError.containerUnavailable
        }

        let folderURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    private static func readManifest(in folderURL: URL) throws -> ICloudExportManifest? {
        let manifestURL = folderURL.appendingPathComponent(ICloudExportConfiguration.manifestFilename, isDirectory: false)
        guard let data = try readCoordinated(at: manifestURL) else { return nil }
        do {
            return try ICloudExportManifest.decode(data)
        } catch let error as ICloudExportManifestError {
            throw error
        } catch {
            // Core Data is authoritative, so a malformed manifest can be rebuilt
            // from the local routes on this reconciliation pass.
            return nil
        }
    }

    private static func writeManifest(_ manifest: ICloudExportManifest, in folderURL: URL) throws {
        let manifestURL = folderURL.appendingPathComponent(ICloudExportConfiguration.manifestFilename, isDirectory: false)
        try writeCoordinated(ICloudExportManifest.encode(manifest), to: manifestURL)
    }

    private static func readCoordinated(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var data: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                data = try Data(contentsOf: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        return data
    }

    private static func writeCoordinated(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private static func removeCoordinatedItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private static func generatedGPXFiles(in folderURL: URL) throws -> [URL] {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var urls: [URL] = []
        coordinator.coordinate(readingItemAt: folderURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: coordinatedURL,
                    includingPropertiesForKeys: nil
                ).filter {
                    let name = $0.lastPathComponent
                    return name.hasPrefix("walk-") && name.hasSuffix(".gpx")
                }
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        return urls
    }

    private static func report(for manifest: ICloudExportManifest, in folderURL: URL) throws -> ICloudExportReport {
        let urls = manifest.walks.map { folderURL.appendingPathComponent($0.filename, isDirectory: false) }
            + [folderURL.appendingPathComponent(ICloudExportConfiguration.manifestFilename, isDirectory: false)]
        let uploaded = urls.allSatisfy { url in
            (try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]).ubiquitousItemIsUploaded) == true
        }
        return ICloudExportReport(routeCount: manifest.walks.count, allFilesUploaded: uploaded, folderURL: folderURL)
    }
}

private enum ICloudGPXPublisherError: LocalizedError {
    case containerUnavailable

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            "iCloud Drive is unavailable. Check that you’re signed in and iCloud Drive is enabled; saved walks remain on this iPhone and will retry."
        }
    }
}
