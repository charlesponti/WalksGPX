import SwiftUI
import UniformTypeIdentifiers

struct ImportedWalk: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let data: Data
}

private extension UTType {
    static let gpx = UTType(filenameExtension: "gpx") ?? .xml
}

struct ContentView: View {
    @State private var walks: [ImportedWalk] = []
    @State private var showingImporter = false
    @State private var selectedWalk: ImportedWalk?

    var body: some View {
        NavigationSplitView {
            List(walks, selection: $selectedWalk) { walk in
                Label(walk.name, systemImage: "figure.walk")
            }
            .navigationTitle("Walks")
            .toolbar { Button { showingImporter = true } label: { Image(systemName: "plus") } }
        } detail: {
            if let walk = selectedWalk {
                VStack(spacing: 16) {
                    Image(systemName: "map")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text(walk.name).font(.title2.bold())
                    Text("Ready to save as GPX")
                        .foregroundStyle(.secondary)
                    Button("Save GPX…") { save(walk) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Import a walk", systemImage: "figure.walk", description: Text("Use the iPhone companion to export a walk, then open its GPX file here."))
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.gpx], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard url.startAccessingSecurityScopedResource(), let data = try? Data(contentsOf: url) else { continue }
                walks.append(ImportedWalk(name: url.lastPathComponent, data: data))
                url.stopAccessingSecurityScopedResource()
            }
        }
        .task { refreshStoredWalks() }
    }

    private func refreshStoredWalks() {
        let synced = WalkStore.shared.fetchRoutes().map { route in
            ImportedWalk(name: route.filename, data: GPXExporter.data(for: route))
        }
        let imported = walks.filter { importedWalk in
            !synced.contains(where: { syncedWalk in syncedWalk.name == importedWalk.name })
        }
        walks = synced + imported
        if selectedWalk == nil { selectedWalk = walks.first }
    }

    private func save(_ walk: ImportedWalk) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gpx]
        panel.nameFieldStringValue = walk.name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? walk.data.write(to: url)
        }
    }
}

@main
struct WalksGPXMacApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
