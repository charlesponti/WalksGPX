import Foundation

struct WalkRoute: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let locations: [RouteLocation]

    var duration: String {
        let minutes = max(1, Int(endDate.timeIntervalSince(startDate) / 60))
        return "\(minutes) min"
    }

    var filename: String {
        "walk-\(Self.filenameDate.string(from: startDate)).gpx"
    }

    private static let filenameDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

struct RouteLocation: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date

    var isValidGPXPoint: Bool {
        latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}
