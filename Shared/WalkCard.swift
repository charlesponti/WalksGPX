import Combine
import Foundation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

private extension UTType {
    static let gpx = UTType(filenameExtension: "gpx") ?? .xml
}

struct GPXFile: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .gpx) { $0.data }
    }
}

@MainActor
protocol WalkLibraryDataSource: AnyObject {
    func waitUntilReady() async
    func fetchWalkMonths(calendar: Calendar) async throws -> [WalkMonth]
    func fetchRouteSummaryPage(
        limit: Int,
        before cursor: WalkRoutePageCursor?,
        in month: WalkMonth?,
        filter: WalkSearchFilter?
    ) async throws -> WalkRouteSummaryPage
    func fetchRoute(id: UUID) async throws -> WalkRoute?
}

extension WalkStore: WalkLibraryDataSource {}

@MainActor
final class WalkLibraryModel: ObservableObject {
    @Published private(set) var months: [WalkMonth] = []
    @Published private(set) var walks: [WalkRouteSummary] = []
    @Published private(set) var selectedWalk: WalkRouteSummary?
    @Published private(set) var filter = WalkSearchFilter()
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published var selectedMonthID: Date?

    private let store: any WalkLibraryDataSource
    private let pageSize: Int
    private var nextCursor: WalkRoutePageCursor?
    private var requestID = UUID()

    init(store: any WalkLibraryDataSource = WalkStore.shared, pageSize: Int = 100) {
        self.store = store
        self.pageSize = max(1, pageSize)
    }

    var selectedMonth: WalkMonth? { months.first { $0.id == selectedMonthID } }
    var isFiltering: Bool { filter.isActive }

    func refresh(force: Bool = false) async {
        await store.waitUntilReady()
        do {
            let oldSelection = selectedMonthID
            let refreshed = try await store.fetchWalkMonths(calendar: .current)
            months = refreshed
            if let oldSelection, refreshed.contains(where: { $0.id == oldSelection }) {
                selectedMonthID = oldSelection
            } else {
                selectedMonthID = refreshed.first?.id
            }
            if force || oldSelection != selectedMonthID || walks.isEmpty { await loadFirstPage() }
        } catch {
            errorMessage = "Couldn’t load walk months: \(error.localizedDescription)"
        }
    }

    func selectMonth(_ id: Date?) async {
        selectedMonthID = id
        if filter.isActive { filter = WalkSearchFilter() }
        await loadFirstPage()
    }

    func apply(filter: WalkSearchFilter) async {
        self.filter = filter
        await loadFirstPage()
    }

    func clearFilter() async {
        filter = WalkSearchFilter()
        await loadFirstPage()
    }

    func selectWalk(_ summary: WalkRouteSummary?) { selectedWalk = summary }

    func makeDetailModel() -> WalkDetailModel { WalkDetailModel(store: store) }

    func loadRoute(id: UUID) async throws -> WalkRoute? {
        try await store.fetchRoute(id: id)
    }

    func loadFirstPage() async {
        let currentRequest = UUID()
        requestID = currentRequest
        isLoading = true
        errorMessage = nil
        nextCursor = nil
        hasMore = false
        defer { if requestID == currentRequest { isLoading = false } }
        do {
            let page = try await store.fetchRouteSummaryPage(
                limit: pageSize,
                before: nil,
                in: filter.isActive ? nil : selectedMonth,
                filter: filter.isActive ? filter : nil
            )
            guard requestID == currentRequest else { return }
            walks = page.summaries
            nextCursor = page.nextCursor
            hasMore = page.hasMore
            if let selectedID = selectedWalk?.id,
               let refreshed = page.summaries.first(where: { $0.id == selectedID }) {
                selectedWalk = refreshed
            }
        } catch {
            guard requestID == currentRequest else { return }
            errorMessage = "Couldn’t load walks: \(error.localizedDescription)"
        }
    }

    func loadNextPage() async {
        guard hasMore, let cursor = nextCursor, !isLoading else { return }
        let currentRequest = requestID
        isLoading = true
        defer { if requestID == currentRequest { isLoading = false } }
        do {
            let page = try await store.fetchRouteSummaryPage(
                limit: pageSize,
                before: cursor,
                in: filter.isActive ? nil : selectedMonth,
                filter: filter.isActive ? filter : nil
            )
            guard requestID == currentRequest else { return }
            var knownIDs = Set(walks.map(\.id))
            walks.append(contentsOf: page.summaries.filter { knownIDs.insert($0.id).inserted })
            nextCursor = page.nextCursor
            hasMore = page.hasMore
        } catch {
            guard requestID == currentRequest else { return }
            hasMore = false
            errorMessage = "Couldn’t load more walks: \(error.localizedDescription)"
        }
    }
}

enum WalkDurationFilter: String, CaseIterable, Identifiable {
    case any
    case underThirtyMinutes
    case thirtyToSixtyMinutes
    case oneToTwoHours
    case overTwoHours

    var id: Self { self }
    var title: String {
        switch self {
        case .any: "Any duration"
        case .underThirtyMinutes: "Under 30 minutes"
        case .thirtyToSixtyMinutes: "30–60 minutes"
        case .oneToTwoHours: "1–2 hours"
        case .overTwoHours: "Over 2 hours"
        }
    }

    var range: ClosedRange<TimeInterval>? {
        switch self {
        case .any: nil
        case .underThirtyMinutes: 0...1_799
        case .thirtyToSixtyMinutes: 1_800...3_599
        case .oneToTwoHours: 3_600...7_199
        case .overTwoHours: 7_200...Double.greatestFiniteMagnitude
        }
    }
}

enum WalkDetailState: Equatable {
    case loading
    case ready
    case routeUnavailable
    case failed(String)
}

@MainActor
final class WalkDetailModel: ObservableObject {
    @Published private(set) var route: WalkRoute?
    @Published private(set) var state: WalkDetailState = .loading
    private let store: any WalkLibraryDataSource
    private var requestedID: UUID?

    init(store: any WalkLibraryDataSource = WalkStore.shared) { self.store = store }

    func load(_ summary: WalkRouteSummary) async {
        requestedID = summary.id
        route = nil
        guard summary.hasGPSRoute else { state = .routeUnavailable; return }
        state = .loading
        do {
            let loaded = try await store.fetchRoute(id: summary.id)
            guard !Task.isCancelled, requestedID == summary.id else { return }
            guard let loaded, RouteMapGeometry.coordinates(for: loaded).count >= 2 else {
                state = .routeUnavailable
                return
            }
            route = loaded
            state = .ready
        } catch {
            guard !Task.isCancelled, requestedID == summary.id else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func exportData() async throws -> Data {
        guard let route else { throw WalkDetailExportError.routeUnavailable }
        return await Task.detached(priority: .userInitiated) { GPXExporter.data(for: route) }.value
    }
}

private enum WalkDetailExportError: LocalizedError {
    case routeUnavailable
    var errorDescription: String? { "This walk does not have a readable GPS route to export." }
}

struct WalkLibraryRow: View {
    let summary: WalkRouteSummary
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.startDate, format: .dateTime.hour().minute())
                        .font(.body.weight(.semibold).monospacedDigit())
                    HStack(spacing: 5) {
                        Text(durationLabel)
                        Image(systemName: summary.hasGPSRoute
                              ? "point.topleft.down.to.point.bottomright.curvepath"
                              : "map")
                            .foregroundStyle(summary.hasGPSRoute ? Color.accentColor : Color.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.startDate.formatted(date: .complete, time: .shortened)), \(durationLabel), \(summary.hasGPSRoute ? "GPS route available" : "no GPS route")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Show walk details and route")
    }

    private var durationLabel: String {
        let minutes = max(1, Int(summary.durationSeconds / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        if remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }
}

struct WalkRouteMap: View {
    let route: WalkRoute
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var retryToken = 0
    private var coordinates: [CLLocationCoordinate2D] { RouteMapGeometry.coordinates(for: route) }

    var body: some View {
        VStack(spacing: 8) {
            Map(position: $cameraPosition, interactionModes: .all) {
                if coordinates.count >= 2 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    Annotation("Start", coordinate: coordinates[0]) { RouteEndpointMarker(color: .green) }
                    Annotation("Finish", coordinate: coordinates[coordinates.count - 1]) { RouteEndpointMarker(color: .primary) }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapCompass(); MapScaleView() }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.quaternary, lineWidth: 1)
            }
            .frame(minHeight: 320, idealHeight: 480)
            .accessibilityLabel("Interactive map showing the selected walk route")
            .task(id: "\(route.id)-\(retryToken)") {
                cameraPosition = .region(RouteMapGeometry.region(for: coordinates))
            }
            HStack {
                Label("Route stored on this device", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Recenter") { retryToken += 1 }
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Recenter map on route")
            }
        }
    }
}

private struct RouteEndpointMarker: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

struct WalkDetailScreen: View {
    let summary: WalkRouteSummary
    var onExport: ((WalkRoute) -> Void)?
    @StateObject private var model: WalkDetailModel
    @State private var isPreparingShare = false
    @State private var shareURL: URL?
    @State private var shareError: String?
    @State private var isShowingShareSheet = false

    init(
        summary: WalkRouteSummary,
        onExport: ((WalkRoute) -> Void)? = nil,
        model: WalkDetailModel = WalkDetailModel()
    ) {
        self.summary = summary
        self.onExport = onExport
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                detailBody
            }
            .frame(maxWidth: 1_100, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(summary.startDate.formatted(.dateTime.month(.wide).day().year()))
        .task(id: "\(summary.id)-\(summary.hasGPSRoute)") { await model.load(summary) }
        #if os(iOS)
        .sheet(isPresented: $isShowingShareSheet) {
            if let shareURL { GPXShareSheet(url: shareURL).ignoresSafeArea() }
        }
        #endif
        .alert("Couldn’t prepare GPX", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK") { shareError = nil }
        } message: { Text(shareError ?? "An unexpected error occurred.") }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(summary.startDate, format: .dateTime.weekday(.wide).month(.wide).day().year())
                    .font(.title2.weight(.bold))
                Text("\(summary.startDate.formatted(date: .omitted, time: .shortened)) – \(summary.endDate.formatted(date: .omitted, time: .shortened)) · \(durationLabel)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Label(
                    summary.hasGPSRoute ? "GPS route saved" : "No readable GPS route",
                    systemImage: summary.hasGPSRoute ? "point.topleft.down.to.point.bottomright.curvepath" : "map"
                )
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            exportControl
        }
    }

    @ViewBuilder
    private var detailBody: some View {
        switch model.state {
        case .loading:
            ContentUnavailableView { ProgressView() } description: { Text("Loading route…") }
                .frame(maxWidth: .infinity, minHeight: 320)
        case .ready:
            if let route = model.route { WalkRouteMap(route: route) }
        case .routeUnavailable:
            ContentUnavailableView(
                "Route unavailable", systemImage: "map",
                description: Text("This HealthKit workout is in your archive, but it has no readable GPS route to show or export.")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t load this route", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.load(summary) } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    @ViewBuilder
    private var exportControl: some View {
        if model.state == .ready, let route = model.route {
            #if os(iOS)
            Button { Task { await prepareShare() } } label: {
                Label(isPreparingShare ? "Preparing…" : "Share GPX", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent).disabled(isPreparingShare)
            #else
            Button { onExport?(route) } label: {
                Label("Export GPX…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            #endif
        }
    }

    private var durationLabel: String {
        let minutes = max(1, Int(summary.durationSeconds / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        if remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }

    #if os(iOS)
    private func prepareShare() async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let data = try await model.exportData()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("walk-\(summary.id.uuidString)")
                .appendingPathExtension("gpx")
            try data.write(to: url, options: .atomic)
            shareURL = url
            isShowingShareSheet = true
        } catch {
            shareError = error.localizedDescription
        }
    }
    #endif
}

#if os(iOS)
private struct GPXShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
