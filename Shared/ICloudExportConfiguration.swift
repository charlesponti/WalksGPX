import Foundation

enum ICloudExportConfiguration {
    static let containerIdentifier = "iCloud.io.ponti.walksgpx"
    static let userVisibleFolderName = "Walks GPX"
    static let manifestFilename = "manifest.json"

    static func routeFilename(for id: UUID) -> String {
        "walk-\(id.uuidString.lowercased()).gpx"
    }
}
