import CoreGraphics
import Foundation
import MapKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum RouteThumbnailRenderer {
    enum PointOrigin { case topLeft, bottomLeft }

    private static let imageCache = ThumbnailImageCache()
    private static let maximumRoutePoints = 350

    static func cacheKey(for route: WalkRoute, size: CGSize) -> String {
        let size = normalizedSize(size)
        guard let first = route.locations.first, let last = route.locations.last else {
            return "\(route.id.uuidString)-0-\(Int(size.width))x\(Int(size.height))"
        }
        let endpointBits = [first.latitude, first.longitude, last.latitude, last.longitude]
            .map { String($0.bitPattern) }
            .joined(separator: "-")
        return "\(route.id.uuidString)-\(route.locations.count)-\(endpointBits)-\(Int(size.width))x\(Int(size.height))"
    }

    static func image(
        for route: WalkRoute,
        size: CGSize,
        snapshot: ((CGSize, [CLLocationCoordinate2D]) async -> CGImage?)? = nil
    ) async -> CGImage? {
        let size = normalizedSize(size)
        let key = cacheKey(for: route, size: size)
        if let cached = imageCache.value(for: key) { return cached }

        let coordinates = routeCoordinates(for: route)
        guard coordinates.count >= 2 else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = RouteMapGeometry.region(for: coordinates)
        options.size = size
        options.mapType = .standard
        let rendered: CGImage?
        if let snapshot {
            rendered = await snapshot(size, coordinates)
        } else {
            rendered = await snapshotImage(options: options, coordinates: coordinates)
        }
        guard let rendered else { return nil }

        imageCache.insert(rendered, for: key)
        return rendered
    }

    static func routeCoordinates(for route: WalkRoute) -> [CLLocationCoordinate2D] {
        let valid = RouteMapGeometry.coordinates(for: route)
        guard valid.count > maximumRoutePoints else { return valid }
        return (0..<maximumRoutePoints).map { sample in
            valid[sample * (valid.count - 1) / (maximumRoutePoints - 1)]
        }
    }

    private static func normalizedSize(_ size: CGSize) -> CGSize {
        let width = min(max(256, Int((size.width / 32).rounded()) * 32), 1_024)
        let height = max(132, Int((size.height / 8).rounded()) * 8)
        return CGSize(width: width, height: height)
    }

    static func render(baseImage: CGImage?, routePoints: [CGPoint], mapSize: CGSize) -> CGImage? {
        let outputScale: CGFloat = 2
        let outputWidth = max(1, Int((mapSize.width * outputScale).rounded()))
        let outputHeight = max(1, Int((mapSize.height * outputScale).rounded()))
        guard let baseImage, routePoints.count >= 2,
              let context = CGContext(
                  data: nil,
                  width: outputWidth,
                  height: outputHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // Snapshot points and bitmap pixels are different coordinate spaces. Fill
        // the output bitmap with the complete snapshot, then scale route points
        // from MapKit's point-space into that same bitmap space.
        let scaleX = CGFloat(outputWidth) / mapSize.width
        let scaleY = CGFloat(outputHeight) / mapSize.height
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        #if os(macOS)
        // MapKit's NSPoint uses AppKit's bottom-left origin, matching CGContext.
        let pointOrigin: PointOrigin = .bottomLeft
        #else
        // UIKit snapshot points start at the top-left; CGContext does not.
        let pointOrigin: PointOrigin = .topLeft
        #endif
        let bitmapRoutePoints = routePoints.map {
            bitmapPoint($0, mapSize: mapSize, scaleX: scaleX, scaleY: scaleY, origin: pointOrigin)
        }
        let lineScale = (scaleX + scaleY) / 2

        context.setShouldAntialias(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        for (index, point) in bitmapRoutePoints.enumerated() {
            if index == 0 { context.move(to: point) }
            else { context.addLine(to: point) }
        }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(5.5 * lineScale)
        context.strokePath()

        context.beginPath()
        for (index, point) in bitmapRoutePoints.enumerated() {
            if index == 0 { context.move(to: point) }
            else { context.addLine(to: point) }
        }
        #if os(iOS)
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        #else
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        #endif
        context.setLineWidth(3.25 * lineScale)
        context.strokePath()
        return context.makeImage()
    }

    static func bitmapPoint(
        _ point: CGPoint,
        mapSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat,
        origin: PointOrigin
    ) -> CGPoint {
        let y = origin == .bottomLeft ? point.y : mapSize.height - point.y
        return CGPoint(x: point.x * scaleX, y: y * scaleY)
    }

    private static func snapshotImage(
        options: MKMapSnapshotter.Options,
        coordinates: [CLLocationCoordinate2D]
    ) async -> CGImage? {
        let mapSize = options.size
        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { continuation in
            snapshotter.start(with: DispatchQueue.global(qos: .utility)) { snapshot, _ in
                guard let snapshot else {
                    continuation.resume(returning: nil)
                    return
                }
                let routePoints = coordinates.map(snapshot.point(for:))
                let image = render(
                    baseImage: cgImage(from: snapshot.image),
                    routePoints: routePoints,
                    mapSize: mapSize
                )
                continuation.resume(returning: image)
            }
        }
    }

    #if os(iOS)
    private static func cgImage(from image: UIImage) -> CGImage? { image.cgImage }
    #else
    private static func cgImage(from image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    #endif
}

private final class ThumbnailImageCache: @unchecked Sendable {
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    func value(for key: String) -> CGImage? { cache.object(forKey: key as NSString) }
    func insert(_ image: CGImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }
}
