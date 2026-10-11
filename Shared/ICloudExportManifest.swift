import Foundation

struct ICloudExportManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let walks: [ICloudExportManifestEntry]

    init(routes: [WalkRoute], generatedAt: Date = .now) {
        var routesByID: [UUID: WalkRoute] = [:]
        for route in routes {
            routesByID[route.id] = route
        }
        self.init(entries: routesByID.values.map(ICloudExportManifestEntry.init(route:)), generatedAt: generatedAt)
    }

    init(entries: [ICloudExportManifestEntry], generatedAt: Date = .now) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        var entriesByID: [UUID: ICloudExportManifestEntry] = [:]
        for entry in entries {
            entriesByID[entry.id] = entry
        }
        walks = entriesByID.values.sorted {
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func encode(_ manifest: ICloudExportManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestampFormatter().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    static func decode(_ data: Data) throws -> ICloudExportManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = Self.timestampFormatter()
            if let date = fractional.date(from: value) { return date }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected an ISO-8601 timestamp."
            )
        }
        let manifest = try decoder.decode(ICloudExportManifest.self, from: data)
        guard manifest.schemaVersion == currentSchemaVersion else {
            throw ICloudExportManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

struct ICloudExportManifestEntry: Codable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let startDate: Date
    let endDate: Date
    let pointCount: Int

    init(route: WalkRoute) {
        id = route.id
        filename = Self.filename(for: route.id)
        startDate = route.startDate
        endDate = route.endDate
        pointCount = route.locations.count
    }

    static func filename(for id: UUID) -> String {
        ICloudExportConfiguration.routeFilename(for: id)
    }
}

enum ICloudExportManifestError: LocalizedError, Equatable {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "The iCloud export manifest uses unsupported schema version \(version)."
        }
    }
}
