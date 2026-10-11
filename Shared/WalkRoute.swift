import Foundation

struct WalkRoute: Identifiable, Codable, Hashable {
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
        return formatter
    }()
}

struct RouteLocation: Codable, Hashable {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date
}
