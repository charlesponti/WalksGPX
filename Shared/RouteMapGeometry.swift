import MapKit

enum RouteMapGeometry {
    static func coordinates(for route: WalkRoute) -> [CLLocationCoordinate2D] {
        route.locations.compactMap { location in
            guard location.isValidGPXPoint else { return nil }
            return CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        }
    }

    static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let adjustedLongitudes: [CLLocationDegrees]
        if longitudes.max()! - longitudes.min()! > 180 {
            adjustedLongitudes = longitudes.map { $0 < 0 ? $0 + 360 : $0 }
        } else {
            adjustedLongitudes = longitudes
        }
        let longitudeCenter = (adjustedLongitudes.min()! + adjustedLongitudes.max()!) / 2
        let normalizedLongitude = longitudeCenter > 180 ? longitudeCenter - 360 : longitudeCenter

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (latitudes.min()! + latitudes.max()!) / 2,
                longitude: normalizedLongitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((latitudes.max()! - latitudes.min()!) * 1.35, 0.002),
                longitudeDelta: max((adjustedLongitudes.max()! - adjustedLongitudes.min()!) * 1.35, 0.002)
            )
        )
    }
}
