import Combine
import CoreData
import Lottie
import SwiftUI

struct WalkingAnimationView: View {
    private static let animation = LottieAnimation.named("walking")

    var body: some View {
        Group {
            if let animation = Self.animation {
                LottieView(animation: animation)
                    .playing(loopMode: .loop)
                    .animationSpeed(1)
            } else {
                Image(systemName: "figure.walk")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
        .aspectRatio(584.0 / 412.0, contentMode: .fit)
        .frame(width: 110, height: 78)
        .accessibilityLabel("Walking")
    }
}

private struct BackgroundSyncAccessory: View {
    let title: String
    let detail: String
    let progress: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .font(.body.weight(.semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    if let progress { ProgressView(value: progress).tint(.blue) }
                }
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 15, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Show sync details")
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var healthKit: HealthKitService
    @StateObject private var library: WalkLibraryModel
    @State private var path: [WalkRouteSummary] = []
    @State private var showingHistoryImportConfirmation = false
    @State private var showingFilter = false
    @State private var showingSyncActivity = false

    init(healthKit: HealthKitService, library: WalkLibraryModel = WalkLibraryModel()) {
        self.healthKit = healthKit
        _library = StateObject(wrappedValue: library)
    }

    var body: some View {
        NavigationStack(path: $path) {
            libraryContent
                .navigationTitle("Walks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        monthPicker
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showingFilter = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Find walks by date and duration")
                        Menu {
                            Button("Refresh Health") { Task { await syncHealth() } }
                            Button("Import all history") { showingHistoryImportConfirmation = true }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(healthKit.isSyncInProgress)
                        .accessibilityLabel("Sync options")
                    }
                }
                .navigationDestination(for: WalkRouteSummary.self) { summary in
                    WalkDetailScreen(summary: currentSummary(for: summary.id) ?? summary)
                        .toolbar(.hidden, for: .tabBar)
                }
        }
        .sheet(isPresented: $showingFilter) {
            WalkLibraryFilterSheet(filter: library.filter) { filter in
                Task { await library.apply(filter: filter) }
            }
        }
        .sheet(isPresented: $showingSyncActivity) {
            SyncActivitySheet(healthKit: healthKit)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Import all walking history?", isPresented: $showingHistoryImportConfirmation) {
            Button("Import", role: .none) {
                Task {
                    await healthKit.importFullHistory()
                    await healthKit.loadStoredWalks()
                    await library.refresh(force: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This checks every walking workout in HealthKit. Existing routes are kept and reused.")
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                .receive(on: DispatchQueue.main)
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        ) { _ in
            Task {
                await library.refresh(force: true)
                await healthKit.loadStoredWalks()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await library.refresh(force: true)
                await healthKit.loadStoredWalks()
            }
        }
        .onChange(of: library.walks) { _, summaries in
            guard let current = path.last,
                  let updated = summaries.first(where: { $0.id == current.id })
            else { return }
            path[path.count - 1] = updated
        }
        .task {
            await library.refresh()
            await healthKit.loadStoredWalks()
            BackgroundSyncScheduler.schedule()
            if healthKit.hasConnected {
                await syncHealth()
            } else {
                await healthKit.retryICloudExport()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if healthKit.isLoading {
                let display = SyncProgressDisplay(processed: healthKit.processedWalks, total: healthKit.totalWalks)
                BackgroundSyncAccessory(
                    title: "Syncing walks",
                    detail: display.detail,
                    progress: display.fraction
                ) { showingSyncActivity = true }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else if healthKit.isExportingToICloud {
                BackgroundSyncAccessory(
                    title: "Updating iCloud Drive",
                    detail: "\(healthKit.iCloudExportCompletedRouteCount) of \(healthKit.iCloudExportTotalRouteCount)",
                    progress: healthKit.iCloudExportProgress
                ) { showingSyncActivity = true }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else if healthKit.iCloudExportMessage?.localizedCaseInsensitiveContains("retry") == true {
                BackgroundSyncAccessory(
                    title: "iCloud update needs attention",
                    detail: "Walks are safe",
                    progress: nil
                ) { showingSyncActivity = true }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if library.isLoading && library.walks.isEmpty && library.months.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                Text("Loading your walks…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.months.isEmpty {
            ContentUnavailableView {
                Label("Your walk archive is ready", systemImage: "figure.walk")
            } description: {
                Text(healthKit.hasConnected
                    ? "No walking workouts are visible yet. Check Health access for Workouts and Workout Routes, then refresh."
                    : "Connect Health to find your walking workouts and GPS routes.")
            } actions: {
                Button(healthKit.hasConnected ? "Refresh Health" : "Connect Health") {
                    Task {
                        if healthKit.hasConnected {
                            await syncHealth()
                        } else {
                            await healthKit.requestAccessAndLoad()
                            await healthKit.loadStoredWalks()
                            await library.refresh(force: true)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(library.isFiltering ? "Matching walks" : (library.selectedMonth?.title ?? "Walks"))
                                .font(.title2.weight(.bold))
                            Text(library.isFiltering ? "Date and duration filters" : "\(library.selectedMonth?.walkCount.formatted() ?? "0") walks")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if library.isFiltering {
                            Button("Clear") { Task { await library.clearFilter() } }
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)

                    ForEach(dayKeys, id: \.self) { day in
                        Section {
                            ForEach(walks(on: day)) { summary in
                                WalkLibraryRow(summary: summary) {
                                    path.append(summary)
                                }
                                .padding(.horizontal, 8)
                            }
                        } header: {
                            Text(day.formatted(date: .complete, time: .omitted))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                                .padding(.horizontal, 18)
                                .padding(.top, 13)
                                .padding(.bottom, 4)
                        }
                    }

                    if library.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(16)
                    } else if library.hasMore {
                        Color.clear
                            .frame(height: 1)
                            .task(id: library.walks.last?.id) { await library.loadNextPage() }
                    }
                    if library.walks.isEmpty && !library.isLoading {
                        ContentUnavailableView(
                            "No matching walks",
                            systemImage: "magnifyingglass",
                            description: Text("Adjust the date or duration filters.")
                        )
                        .padding(.top, 40)
                    }
                    if let error = library.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding()
                    }
                }
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var monthPicker: some View {
        Menu {
            ForEach(Array(Set(library.months.map(\.year))).sorted(by: >), id: \.self) { year in
                Section(String(year)) {
                    ForEach(library.months.filter { $0.year == year }) { month in
                        Button {
                            Task { await library.selectMonth(month.id) }
                        } label: {
                            if month.id == library.selectedMonthID {
                                Label("\(month.title) · \(month.walkCount)", systemImage: "checkmark")
                            } else {
                                Text("\(month.title) · \(month.walkCount)")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                Text(library.isFiltering ? "All dates" : (library.selectedMonth?.title ?? "Walks"))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Choose month")
    }

    private var dayKeys: [Date] {
        Array(Set(library.walks.map { Calendar.current.startOfDay(for: $0.startDate) })).sorted(by: >)
    }

    private func walks(on day: Date) -> [WalkRouteSummary] {
        library.walks.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    }

    func currentSummary(for id: UUID) -> WalkRouteSummary? {
        library.walks.first(where: { $0.id == id })
    }

    func syncHealth() async {
        await healthKit.loadWalks()
        await healthKit.loadStoredWalks()
        await library.refresh(force: true)
    }
}

struct WalkLibraryFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var filtersByDate: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var duration: WalkDurationFilter
    let apply: (WalkSearchFilter) -> Void

    init(filter: WalkSearchFilter, apply: @escaping (WalkSearchFilter) -> Void) {
        _filtersByDate = State(initialValue: filter.startDate != nil || filter.endDate != nil)
        _startDate = State(initialValue: filter.startDate ?? Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now)
        _endDate = State(initialValue: filter.endDate?.addingTimeInterval(-1) ?? .now)
        _duration = State(initialValue: Self.durationFilter(for: filter))
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date range") {
                    Toggle("Filter by date", isOn: $filtersByDate)
                    if filtersByDate {
                        DatePicker("From", selection: $startDate, displayedComponents: .date)
                        DatePicker("Through", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }
                Section("Duration") {
                    Picker("Length", selection: $duration) {
                        ForEach(WalkDurationFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                }
            }
            .navigationTitle("Find walks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show walks") {
                        apply(Self.makeFilter(
                            filtersByDate: filtersByDate,
                            startDate: startDate,
                            endDate: endDate,
                            duration: duration
                        ))
                        dismiss()
                    }
                }
            }
        }
    }

    private static func durationFilter(for filter: WalkSearchFilter) -> WalkDurationFilter {
        switch (filter.minimumDuration, filter.maximumDuration) {
        case (nil, nil): .any
        case (nil, let max?) where max < 1_800: .underThirtyMinutes
        case (let min?, let max?) where min >= 1_800 && max < 3_600: .thirtyToSixtyMinutes
        case (let min?, let max?) where min >= 3_600 && max < 7_200: .oneToTwoHours
        case (let min?, nil) where min >= 7_200: .overTwoHours
        default: .any
        }
    }

    static func makeFilter(
        filtersByDate: Bool,
        startDate: Date,
        endDate: Date,
        duration: WalkDurationFilter,
        calendar: Calendar = .current
    ) -> WalkSearchFilter {
        let start = calendar.startOfDay(for: startDate)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate))
        let range = duration.range
        return WalkSearchFilter(
            startDate: filtersByDate ? start : nil,
            endDate: filtersByDate ? endExclusive : nil,
            minimumDuration: range?.lowerBound,
            maximumDuration: range?.upperBound
        )
    }
}

struct SyncActivitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var healthKit: HealthKitService

    var body: some View {
        NavigationStack {
            List {
                Section("HealthKit") {
                    let progressDisplay = SyncProgressDisplay(processed: healthKit.processedWalks, total: healthKit.totalWalks)
                    LabeledContent(
                        "Status",
                        value: healthKit.isLoading
                            ? (healthKit.totalWalks > 0 ? "Updating walks" : "Checking")
                            : (healthKit.hasConnected ? "Ready" : "Not connected")
                    )
                    if healthKit.isLoading {
                        if let fraction = progressDisplay.fraction {
                            ProgressView(value: fraction)
                            LabeledContent("Workouts", value: progressDisplay.detail)
                        } else {
                            Text("Checking HealthKit for new workouts…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Saved walks", value: healthKit.savedWalkCount.formatted())
                    LabeledContent("GPS routes", value: healthKit.savedRouteCount.formatted())
                    LabeledContent("Waiting for a route", value: healthKit.pendingRouteCount.formatted())
                    if let message = healthKit.syncMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("iCloud Drive") {
                    LabeledContent("Status", value: healthKit.isExportingToICloud ? "Updating" : "Available when connected")
                    if healthKit.isExportingToICloud, let progress = healthKit.iCloudExportProgress {
                        ProgressView(value: progress)
                        LabeledContent("Routes", value: "\(healthKit.iCloudExportCompletedRouteCount) of \(healthKit.iCloudExportTotalRouteCount)")
                    }
                    if let message = healthKit.iCloudExportMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Retry iCloud Drive update") { Task { await healthKit.retryICloudExport() } }
                        .disabled(healthKit.isExportingToICloud)
                    Button("Repair iCloud Drive folder") { Task { await healthKit.repairICloudExportFolder() } }
                        .disabled(healthKit.isExportingToICloud)
                }
                if let error = healthKit.errorMessage {
                    Section("Needs attention") { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Sync activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
