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

struct WalkingAnimationView: View {
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

struct WalkMapPreview: View {
    let walk: WalkRoute
    var height: CGFloat = 160

    private var coordinates: [CLLocationCoordinate2D] {
        RouteMapGeometry.coordinates(for: walk)
    }

    private var region: MKCoordinateRegion {
        RouteMapGeometry.region(for: coordinates)
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
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(coordinates.count >= 2 ? "Map preview of walk route" : "No GPS route preview")
    }
}

struct WalkCard: View {
    let walk: WalkRoute

    var body: some View {
        VStack(spacing: 0) {
            WalkMapPreview(walk: walk, height: 132)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(walk.startDate, format: .dateTime.weekday(.wide).month().day().year())
                        .font(.headline)
                    Text("\(walk.duration) · \(walk.locations.count) points")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: GPXFile(data: GPXExporter.data(for: walk)), preview: SharePreview(walk.filename)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.quaternary, in: Circle())
                }
                .accessibilityLabel("Share \(walk.filename)")
            }
            .padding(14)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct AppHeader: View {
    let isSyncing: Bool
    let refresh: () -> Void
    let importHistory: () -> Void

    var body: some View {
        HStack {
            Text("Walks GPX")
                .font(.title3.weight(.bold))
            Spacer()
            Menu {
                Button(action: refresh) {
                    Label("Refresh Health", systemImage: "arrow.clockwise")
                }
                Button(action: importHistory) {
                    Label("Import all history", systemImage: "clock.arrow.circlepath")
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(.quaternary, in: Circle())
            }
            .disabled(isSyncing)
            .accessibilityLabel("Sync options")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }
}

private struct BackgroundSyncAccessory: View {
    enum Kind {
        case health
        case iCloud
    }

    let kind: Kind
    let title: String
    let detail: String
    let progress: Double?
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind == .health ? "figure.walk" : "icloud.and.arrow.up")
                .font(.body.weight(.semibold))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .monospacedDigit()
                        .lineLimit(1)
                }

                if let progress {
                    ProgressView(value: progress)
                        .tint(.blue)
                }
            }

            if let retry {
                Button("Retry", action: retry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 7)
        .accessibilityElement(children: .combine)
    }
}

struct ContentView: View {
    @ObservedObject var healthKit: HealthKitService
    @State private var exportedURL: URL?
    @State private var showingHistoryImportConfirmation = false

    #if DEBUG
    private static let previewingSync = ProcessInfo.processInfo.arguments.contains("--preview-sync")
    #else
    private static let previewingSync = false
    #endif

    #if DEBUG
    private static let previewWalks = [
        WalkRoute(
            id: UUID(),
            startDate: .now.addingTimeInterval(-2_700),
            endDate: .now,
            locations: [
                RouteLocation(latitude: 51.5074, longitude: -0.1278, elevation: nil, timestamp: .now.addingTimeInterval(-2_700)),
                RouteLocation(latitude: 51.5082, longitude: -0.1252, elevation: nil, timestamp: .now)
            ]
        ),
        WalkRoute(
            id: UUID(),
            startDate: .now.addingTimeInterval(-86_400 - 1_980),
            endDate: .now.addingTimeInterval(-86_400),
            locations: [
                RouteLocation(latitude: 51.5100, longitude: -0.1200, elevation: nil, timestamp: .now.addingTimeInterval(-86_400 - 1_980)),
                RouteLocation(latitude: 51.5110, longitude: -0.1170, elevation: nil, timestamp: .now.addingTimeInterval(-86_400))
            ]
        )
    ]
    #endif

    private var displayedWalks: [WalkRoute] {
        #if DEBUG
        Self.previewingSync ? Self.previewWalks : healthKit.walks
        #else
        healthKit.walks
        #endif
    }

    private var isInitialSync: Bool {
        healthKit.isLoading && displayedWalks.isEmpty
    }

    private var shouldShowICloudRetry: Bool {
        !healthKit.isExportingToICloud
            && healthKit.iCloudExportMessage?.localizedCaseInsensitiveContains("retry") == true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppHeader(
                    isSyncing: healthKit.isLoading,
                    refresh: { Task { await healthKit.loadWalks() } },
                    importHistory: { showingHistoryImportConfirmation = true }
                )

                if isInitialSync {
                    VStack(spacing: 18) {
                        WalkingAnimationView()
                        Text("Syncing your walks")
                            .font(.title2.bold())
                        ProgressView(value: healthKit.progress)
                            .frame(maxWidth: 280)
                        Text("Reading \(healthKit.processedWalks) of \(healthKit.totalWalks) workouts…")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("Your walks will appear here as soon as the first route is saved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedWalks.isEmpty {
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Your walks")
                                    .font(.title.bold())
                                Spacer()
                                Text("\(displayedWalks.count) saved")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 2)

                            ForEach(displayedWalks) { walk in
                                WalkCard(walk: walk)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("Import all walking history?", isPresented: $showingHistoryImportConfirmation) {
                Button("Import", role: .none) {
                    Task { await healthKit.importFullHistory() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This reads every walking workout from HealthKit again. Existing saved routes are kept and duplicates are updated by workout ID.")
            }
            .alert("Couldn’t read walks", isPresented: Binding(get: { healthKit.errorMessage != nil }, set: { if !$0 { healthKit.errorMessage = nil } })) {
                Button("OK") { healthKit.errorMessage = nil }
            } message: { Text(healthKit.errorMessage ?? "Unknown error") }
            .safeAreaInset(edge: .bottom) {
                if (healthKit.isLoading || Self.previewingSync) && !displayedWalks.isEmpty {
                    BackgroundSyncAccessory(
                        kind: .health,
                        title: "Syncing your walks",
                        detail: healthKit.totalWalks > 0
                            ? "\(healthKit.processedWalks) of \(healthKit.totalWalks)"
                            : "Starting…",
                        progress: healthKit.totalWalks > 0 ? healthKit.progress : nil,
                        retry: nil
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                } else if healthKit.isExportingToICloud || shouldShowICloudRetry {
                    BackgroundSyncAccessory(
                        kind: .iCloud,
                        title: healthKit.isExportingToICloud
                            ? "Updating your walk folder"
                            : "iCloud update needs a retry",
                        detail: healthKit.isExportingToICloud
                            ? "\(healthKit.iCloudExportCompletedRouteCount) of \(healthKit.iCloudExportTotalRouteCount)"
                            : "Walks are safe",
                        progress: healthKit.isExportingToICloud ? healthKit.iCloudExportProgress : nil,
                        retry: shouldShowICloudRetry ? {
                            Task { await healthKit.retryICloudExport() }
                        } : nil
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .task {
                await WalkStore.shared.waitUntilReady()
                healthKit.loadStoredWalks()
                Task { await healthKit.retryICloudExport() }
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
