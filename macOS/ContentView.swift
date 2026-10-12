import Combine
import CoreData
import SwiftUI
import UniformTypeIdentifiers

enum MacLibrarySelection: Hashable {
    case walk(UUID)
    case file(String)
}

struct ImportedGPXFile: Identifiable, Hashable {
    let id: String
    let name: String
    let data: Data
}

private extension UTType {
    static let gpx = UTType(filenameExtension: "gpx") ?? .xml
}

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: WalkLibraryModel
    @State private var selection: MacLibrarySelection?
    @State private var importedFiles: [ImportedGPXFile] = []
    @State private var isShowingImporter = false
    @State private var isShowingFilter = false
    @State private var alertMessage: String?
    private let onExportRoute: ((WalkRoute) -> Void)?

    init(
        library: WalkLibraryModel = WalkLibraryModel(),
        importedFiles: [ImportedGPXFile] = [],
        onExportRoute: ((WalkRoute) -> Void)? = nil
    ) {
        _library = StateObject(wrappedValue: library)
        _importedFiles = State(initialValue: importedFiles)
        self.onExportRoute = onExportRoute
    }

    var body: some View {
        NavigationSplitView {
            monthSidebar
        } content: {
            walkList
        } detail: {
            selectedDetail
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 205, max: 250)
        .navigationSplitViewColumnWidth(min: 250, ideal: 330, max: 430)
        .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: [.gpx], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls where url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                guard let data = try? Data(contentsOf: url) else { continue }
                let file = ImportedGPXFile(
                    id: url.standardizedFileURL.path,
                    name: url.lastPathComponent,
                    data: data
                )
                if !importedFiles.contains(where: { $0.id == file.id }) {
                    importedFiles.append(file)
                }
            }
        }
        .sheet(isPresented: $isShowingFilter) {
            WalkLibraryFilterSheet(filter: library.filter) { filter in
                Task { await library.apply(filter: filter) }
            }
        }
        .alert("Walks GPX", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "An unexpected error occurred.")
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                .receive(on: DispatchQueue.main)
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        ) { _ in
            Task { await refresh(force: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh(force: true) } }
        }
        .task {
            await refresh()
        }
        .onChange(of: library.walks.map(\.id)) { _, ids in
            guard case .walk = selection, let selectedID = library.selectedWalk?.id,
                  !ids.contains(selectedID) else { return }
            selection = ids.first.map(MacLibrarySelection.walk)
            library.selectWalk(library.walks.first)
        }
    }

    private var monthSidebar: some View {
        List(selection: Binding(
            get: { library.selectedMonthID },
            set: { id in Task { await library.selectMonth(id) } }
        )) {
            ForEach(Array(Set(library.months.map(\.year))).sorted(by: >), id: \.self) { year in
                Section(String(year)) {
                    ForEach(library.months.filter { $0.year == year }) { month in
                        HStack {
                            Text(month.monthName)
                            Spacer()
                            Text(month.walkCount.formatted())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(month.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Walks")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh walks")
                Button { isShowingImporter = true } label: {
                    Image(systemName: "plus")
                }
                .help("Import GPX files")
            }
        }
        .overlay {
            if library.months.isEmpty && !library.isLoading {
                ContentUnavailableView(
                    "No walks yet",
                    systemImage: "figure.walk",
                    description: Text("Walks saved on your iPhone appear here after iCloud sync.")
                )
            }
        }
    }

    private var walkList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.isFiltering ? "Find walks" : (library.selectedMonth?.title ?? "Walks"))
                        .font(.title2.weight(.bold))
                    Text(listCountLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    isShowingFilter = true
                } label: {
                    Label(library.isFiltering ? "Filters" : "Find", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .help("Find walks by date and duration")
                if library.isFiltering {
                    Button("Clear") { Task { await library.clearFilter() } }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            List(selection: selectionBinding) {
                ForEach(dayKeys, id: \.self) { day in
                    Section(day.formatted(date: .complete, time: .omitted)) {
                        ForEach(walks(on: day)) { summary in
                            WalkLibraryRow(
                                summary: summary,
                                isSelected: library.selectedWalk?.id == summary.id
                            ) {
                                library.selectWalk(summary)
                                selection = .walk(summary.id)
                            }
                            .contextMenu {
                                Button {
                                    exportWalk(summary)
                                } label: {
                                    Label("Export GPX…", systemImage: "square.and.arrow.down")
                                }
                                .disabled(!summary.hasGPSRoute)
                            }
                            .tag(MacLibrarySelection.walk(summary.id))
                        }
                    }
                }

                if !importedFiles.isEmpty {
                    Section("Imported GPX") {
                        ForEach(importedFiles) { file in
                            Label(file.name, systemImage: "doc.zipped")
                                .lineLimit(1)
                                .tag(MacLibrarySelection.file(file.id))
                        }
                    }
                }

                if library.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                } else if library.hasMore {
                    Button("Load more walks") { Task { await library.loadNextPage() } }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                }
                if let error = library.errorMessage {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .listStyle(.inset)
            .overlay {
                if library.walks.isEmpty && importedFiles.isEmpty && !library.isLoading {
                    ContentUnavailableView(
                        library.isFiltering ? "No matching walks" : "No walks this month",
                        systemImage: library.isFiltering ? "magnifyingglass" : "figure.walk",
                        description: Text(library.isFiltering ? "Adjust the date or duration filters." : "Choose another month from the sidebar.")
                    )
                }
            }
        }
        .navigationTitle(library.selectedMonth?.title ?? "Walks")
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch selection {
        case .walk(let id):
            if let summary = library.selectedWalk?.id == id
                ? library.selectedWalk
                : library.walks.first(where: { $0.id == id }) {
                WalkDetailScreen(summary: summary, onExport: saveGPX, model: library.makeDetailModel())
            } else {
                ContentUnavailableView("Walk unavailable", systemImage: "map")
            }
        case .file(let id):
            if let file = importedFiles.first(where: { $0.id == id }) {
                importedFileDetail(file)
            } else {
                ContentUnavailableView("Choose a walk", systemImage: "figure.walk")
            }
        case nil:
            ContentUnavailableView(
                "Choose a walk",
                systemImage: "figure.walk",
                description: Text("Select a walk to view its route and export a GPX file.")
            )
        }
    }

    func importedFileDetail(_ file: ImportedGPXFile) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.zipped").font(.system(size: 42)).foregroundStyle(.tint)
            Text(file.name).font(.title2.weight(.bold))
            Text("Imported for this session")
                .foregroundStyle(.secondary)
            Button("Save a copy…") { save(data: file.data, named: file.name) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var selectionBinding: Binding<MacLibrarySelection?> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                if case .walk(let id) = newValue {
                    library.selectWalk(library.walks.first(where: { $0.id == id }))
                } else {
                    library.selectWalk(nil)
                }
            }
        )
    }

    private var dayKeys: [Date] {
        Array(Set(library.walks.map { Calendar.current.startOfDay(for: $0.startDate) })).sorted(by: >)
    }

    private func walks(on day: Date) -> [WalkRouteSummary] {
        library.walks.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    }

    private var listCountLabel: String {
        if library.isFiltering { return "\(library.walks.count.formatted()) shown" }
        return "\(library.selectedMonth?.walkCount.formatted() ?? "0") walks"
    }

    private func refresh(force: Bool = false) async {
        await library.refresh(force: force)
        if library.selectedWalk == nil, let first = library.walks.first {
            library.selectWalk(first)
            selection = .walk(first.id)
        } else if let selected = library.selectedWalk,
                  !library.walks.contains(where: { $0.id == selected.id }),
                  let first = library.walks.first {
            library.selectWalk(first)
            selection = .walk(first.id)
        }
    }

    func saveGPX(_ route: WalkRoute) {
        if let onExportRoute {
            onExportRoute(route)
            return
        }
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                GPXExporter.data(for: route)
            }.value
            save(data: data, named: route.filename)
        }
    }

    func exportWalk(_ summary: WalkRouteSummary) {
        Task {
            do {
                guard let route = try await library.loadRoute(id: summary.id) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                saveGPX(route)
            } catch {
                alertMessage = "Couldn’t load this walk for export: \(error.localizedDescription)"
            }
        }
    }

    private func save(data: Data, named name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gpx]
        panel.nameFieldStringValue = name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Task { @MainActor in alertMessage = "Couldn’t save GPX: \(error.localizedDescription)" }
            }
        }
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
        _duration = State(initialValue: WalkLibraryFilterSheet.durationFilter(for: filter))
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show walks") {
                        let calendar = Calendar.current
                        let start = calendar.startOfDay(for: startDate)
                        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate))
                        let range = duration.range
                        apply(WalkSearchFilter(
                            startDate: filtersByDate ? start : nil,
                            endDate: filtersByDate ? endExclusive : nil,
                            minimumDuration: range?.lowerBound,
                            maximumDuration: range?.upperBound
                        ))
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 320)
    }

    static func durationFilter(for filter: WalkSearchFilter) -> WalkDurationFilter {
        switch (filter.minimumDuration, filter.maximumDuration) {
        case (nil, nil): .any
        case (nil, let max?) where max < 1_800: .underThirtyMinutes
        case (let min?, let max?) where min >= 1_800 && max < 3_600: .thirtyToSixtyMinutes
        case (let min?, let max?) where min >= 3_600 && max < 7_200: .oneToTwoHours
        case (let min?, nil) where min >= 7_200: .overTwoHours
        default: .any
        }
    }
}

@main
struct WalksGPXMacApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
