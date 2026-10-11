import Foundation

enum GPXExporter {
    static func data(for route: WalkRoute) -> Data {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Walks GPX" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata><time>\(dateFormatter.string(from: route.startDate))</time></metadata>
          <trk><name>Walk \(dateFormatter.string(from: route.startDate))</name><trkseg>
        """

        for point in route.locations where point.isValidGPXPoint {
            xml += "\n    <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
            if let elevation = point.elevation, elevation.isFinite { xml += "<ele>\(elevation)</ele>" }
            xml += "<time>\(dateFormatter.string(from: point.timestamp))</time></trkpt>"
        }

        xml += "\n  </trkseg></trk>\n</gpx>\n"
        return Data(xml.utf8)
    }
}
