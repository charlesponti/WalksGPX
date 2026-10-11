import SwiftUI
import UniformTypeIdentifiers
import Lottie
import MapKit

private extension UTType {
    static let gpx = UTType(filenameExtension: "gpx") ?? .xml
}

struct GPXFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .gpx) { file in file.data }
    }
}

private struct WalkingAnimationView: View {
    private static let animation = LottieAnimation.named("walking")

    var body: some View {
        Group {
            if let animation = Self.animation {
                LottieView(animation: animation)
                    .playing(loopMode: .loop)
                    .animationSpeed(1.0)
            } else {
                PhaseAnimator([false, true]) { raised in
                    Image(systemName: "figure.walk")
                        .font(.system(size: 72, weight: .medium))
                        .rotationEffect(.degrees(raised ? 4 : -4))
                        .offset(y: raised ? -3 : 3)
                } animation: { _ in
                    .easeInOut(duration: 0.22)
                }
            }
        }
        .aspectRatio(584.0 / 412.0, contentMode: .fit)
        .frame(width: 140, height: 100)
        .clipped()
        .accessibilityLabel("Walking")
    }
}

private struct WalkMapPreview: View {
    let walk: WalkRoute

    private var coordinates: [CLLocationCoordinate2D] {
        walk.locations.compactMap { location in
            guard location.latitude.isFinite, location.longitude.isFinite,
                  (-90...90).contains(location.latitude), (-180...180).contains(location.longitude) else {
                return nil
            }
            return CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        }
    }

    private var region: MKCoordinateRegion {
        let points = coordinates
        guard !points.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        }

        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        let latitudeDelta = max((latitudes.max()! - latitudes.min()!) * 1.35, 0.002)
        let longitudeDelta = max((longitudes.max()! - longitudes.min()!) * 1.35, 0.002)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (latitudes.min()! + latitudes.max()!) / 2,
                longitude: (longitudes.min()! + longitudes.max()!) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    var body: some View {
        Group {
            if coordinates.count >= 2 {
                Map(initialPosition: .region(region), interactionModes: []) {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.tint, lineWidth: 4)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                    Label("No GPS route preview", systemImage: "map")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(coordinates.count >= 2 ? "Map preview of walk route" : "No GPS route preview")
    }
}

struct ContentView: View {
    @ObservedObject var healthKit: HealthKitService
    @State private var exportedURL: URL?

    #if DEBUG
    private static let previewingSync = ProcessInfo.processInfo.arguments.contains("--preview-sync")
    #else
    private static let previewingSync = false
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if healthKit.isLoading || Self.previewingSync {
                    VStack(spacing: 18) {
                        WalkingAnimationView()
                        Text("Syncing your walks")
                            .font(.title2.bold())
                        ProgressView(value: healthKit.progress)
                            .frame(maxWidth: 280)
                        Text("Reading \(healthKit.processedWalks) of \(healthKit.totalWalks) workouts…")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if let syncMessage = healthKit.syncMessage {
                            Text(syncMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        if healthKit.pendingRouteCount > 0 {
                            Text("Waiting for \(healthKit.pendingRouteCount) GPS route\(healthKit.pendingRouteCount == 1 ? "" : "s")…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if healthKit.walks.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "figure.walk.circle")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text("No route walks yet")
                            .font(.title2.bold())
                        Text("Sync HealthKit to find walks with GPS routes.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if let syncMessage = healthKit.syncMessage {
                            Text(syncMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        Button("Sync Health") {
                            Task {
                                if healthKit.hasConnected {
                                    await healthKit.loadWalks()
                                } else {
                                    await healthKit.requestAccessAndLoad()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(healthKit.walks) { walk in
                        VStack(alignment: .leading, spacing: 12) {
                            WalkMapPreview(walk: walk)

                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(walk.startDate, format: .dateTime.weekday(.wide).month().day().year())
                                        .font(.headline)
                                    Text("\(walk.duration) · \(walk.locations.count) points")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShareLink(item: GPXFile(data: GPXExporter.data(for: walk)), preview: SharePreview(walk.filename)) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("WalksGPX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await healthKit.loadWalks() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(healthKit.isLoading)
                }
            }
            .alert("Couldn’t read walks", isPresented: Binding(get: { healthKit.errorMessage != nil }, set: { if !$0 { healthKit.errorMessage = nil } })) {
                Button("OK") { healthKit.errorMessage = nil }
            } message: { Text(healthKit.errorMessage ?? "Unknown error") }
            .task {
                await WalkStore.shared.waitUntilReady()
                healthKit.loadStoredWalks()
                BackgroundSyncScheduler.schedule()
                if healthKit.hasConnected {
                    await healthKit.loadWalks()
                }
            }
        }
    }
}

@main
struct WalksGPXiOSApp: App {
    @StateObject private var healthKit: HealthKitService

    init() {
        let healthKit = HealthKitService()
        _healthKit = StateObject(wrappedValue: healthKit)
        BackgroundSyncScheduler.register(using: healthKit)
    }

    var body: some Scene { WindowGroup { ContentView(healthKit: healthKit) } }
}
