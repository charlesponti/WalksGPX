import CoreGraphics
import CoreLocation
import XCTest
#if os(iOS)
@testable import WalksGPX_iOS
#else
@testable import WalksGPX_macOS
#endif

final class RouteThumbnailTests: XCTestCase {
    func testCacheKeyChangesWhenRouteEndpointsChange() {
        let id = UUID()
        let first = route(id: id, latitudes: [1, 2, 3])
        let revised = route(id: id, latitudes: [1, 2.5, 3.5])

        XCTAssertNotEqual(
            RouteThumbnailRenderer.cacheKey(for: first, size: CGSize(width: 500, height: 132)),
            RouteThumbnailRenderer.cacheKey(for: revised, size: CGSize(width: 500, height: 132))
        )
        XCTAssertNotEqual(
            RouteThumbnailRenderer.cacheKey(for: first, size: CGSize(width: 500, height: 132)),
            RouteThumbnailRenderer.cacheKey(for: first, size: CGSize(width: 900, height: 132))
        )
    }

    func testCacheKeyUsesNormalizedSnapshotSizeAndHandlesEmptyRoute() {
        let id = UUID()
        let route = route(id: id, latitudes: [1, 2])
        XCTAssertEqual(
            RouteThumbnailRenderer.cacheKey(for: route, size: CGSize(width: 501, height: 135)),
            RouteThumbnailRenderer.cacheKey(for: route, size: CGSize(width: 512, height: 136))
        )
        let empty = WalkRoute(id: id, startDate: .now, endDate: .now, locations: [])
        XCTAssertTrue(RouteThumbnailRenderer.cacheKey(for: empty, size: .zero).contains("-0-256x132"))
    }

    func testImageLoadsSnapshotOnceThenUsesCacheAndReturnsNilForBadRouteOrFailedSnapshot() async {
        let image = makeImage(width: 512, height: 264, fill: CGColor(gray: 0.8, alpha: 1))
        let walk = route(id: UUID(), latitudes: [51.5, 51.501])
        var snapshotCalls = 0
        let snapshot: (CGSize, [CLLocationCoordinate2D]) async -> CGImage? = { size, coordinates in
            snapshotCalls += 1
            XCTAssertEqual(size, CGSize(width: 512, height: 136))
            XCTAssertEqual(coordinates.count, 2)
            return image
        }

        let first = await RouteThumbnailRenderer.image(for: walk, size: CGSize(width: 513, height: 136), snapshot: snapshot)
        let second = await RouteThumbnailRenderer.image(for: walk, size: CGSize(width: 512, height: 136), snapshot: snapshot)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertEqual(snapshotCalls, 1, "The second request must be served from cache")
        let badRoute = route(id: UUID(), latitudes: [91])
        let missingImage = await RouteThumbnailRenderer.image(for: badRoute, size: CGSize(width: 512, height: 136), snapshot: snapshot)
        XCTAssertNil(missingImage)

        let failedRoute = route(id: UUID(), latitudes: [51.5, 51.501])
        let failed = await RouteThumbnailRenderer.image(for: failedRoute, size: CGSize(width: 512, height: 136), snapshot: { _, _ in nil })
        XCTAssertNil(failed)
    }

    func testRouteCoordinatesAreValidAndBoundedWhilePreservingEndpoints() {
        let route = WalkRoute(
            id: UUID(),
            startDate: .now,
            endDate: .now.addingTimeInterval(3_600),
            locations: (0..<1_000).map { index in
                RouteLocation(
                    latitude: 51.5 + Double(index) * 0.00001,
                    longitude: -0.12 + sin(Double(index) / 50) * 0.001,
                    elevation: nil,
                    timestamp: .now.addingTimeInterval(Double(index))
                )
            }
        )

        let coordinates = RouteThumbnailRenderer.routeCoordinates(for: route)

        XCTAssertEqual(coordinates.count, 350)
        XCTAssertEqual(coordinates.first?.latitude, route.locations.first?.latitude)
        XCTAssertEqual(coordinates.last?.latitude, route.locations.last?.latitude)
    }

    func testRendererDrawsRouteOnStaticMapImage() {
        let baseImage = makeImage(width: 256, height: 132, fill: CGColor(gray: 0.9, alpha: 1))
        let points = [CGPoint(x: 20, y: 100), CGPoint(x: 128, y: 30), CGPoint(x: 236, y: 100)]

        let rendered = RouteThumbnailRenderer.render(baseImage: baseImage, routePoints: points, mapSize: CGSize(width: 256, height: 132))

        XCTAssertEqual(rendered?.width, 512)
        XCTAssertEqual(rendered?.height, 264)
    }

    func testRendererRejectsMissingBaseImageAndTooFewPointsAndNormalizesOutputSize() {
        XCTAssertNil(RouteThumbnailRenderer.render(baseImage: nil, routePoints: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)], mapSize: CGSize(width: 100, height: 50)))
        let image = makeImage(width: 80, height: 40, fill: CGColor(gray: 0.9, alpha: 1))
        XCTAssertNil(RouteThumbnailRenderer.render(baseImage: image, routePoints: [CGPoint(x: 1, y: 1)], mapSize: CGSize(width: 100, height: 50)))
        let rendered = RouteThumbnailRenderer.render(baseImage: image, routePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)], mapSize: CGSize(width: 100, height: 50))
        XCTAssertEqual(rendered?.width, 200)
        XCTAssertEqual(rendered?.height, 100)
    }

    func testSnapshotPointOriginsMapNorthToTheSameBitmapPosition() {
        let size = CGSize(width: 256, height: 132)
        let bitmapFromMacPoint = RouteThumbnailRenderer.bitmapPoint(
            CGPoint(x: 128, y: 102), mapSize: size,
            scaleX: 2, scaleY: 2, origin: .bottomLeft
        )
        let bitmapFromIOSPoint = RouteThumbnailRenderer.bitmapPoint(
            CGPoint(x: 128, y: 30), mapSize: size,
            scaleX: 2, scaleY: 2, origin: .topLeft
        )

        XCTAssertEqual(bitmapFromMacPoint, CGPoint(x: 256, y: 204))
        XCTAssertEqual(bitmapFromIOSPoint, bitmapFromMacPoint)
    }

    func testRouteCoordinateSelectionRejectsInsufficientValidPoints() {
        let route = route(id: UUID(), latitudes: [91])

        XCTAssertTrue(RouteThumbnailRenderer.routeCoordinates(for: route).isEmpty)
    }

    private func route(id: UUID, latitudes: [Double]) -> WalkRoute {
        let start = Date.now
        return WalkRoute(
            id: id,
            startDate: start,
            endDate: start.addingTimeInterval(Double(latitudes.count)),
            locations: latitudes.enumerated().map { index, latitude in
                RouteLocation(latitude: latitude, longitude: Double(index), elevation: nil, timestamp: start.addingTimeInterval(Double(index)))
            }
        )
    }

    private func makeImage(width: Int, height: Int, fill color: CGColor) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
