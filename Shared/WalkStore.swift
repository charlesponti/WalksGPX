import CoreData
import Foundation

@objc(PersistedWalk)
final class PersistedWalk: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var startDate: Date
    @NSManaged var endDate: Date
    @NSManaged var locationsData: Data
}

extension PersistedWalk {
    @nonobjc class func fetchRequest() -> NSFetchRequest<PersistedWalk> {
        NSFetchRequest<PersistedWalk>(entityName: "PersistedWalk")
    }

    var route: WalkRoute? {
        guard let locations = try? JSONDecoder().decode([RouteLocation].self, from: locationsData) else { return nil }
        return WalkRoute(id: id, startDate: startDate, endDate: endDate, locations: locations)
    }
}

@MainActor
final class WalkStore {
    static let shared = WalkStore()

    let container: NSPersistentContainer
    private(set) var loadError: Error?
    private var isReady = false
    private var readinessContinuations: [CheckedContinuation<Void, Never>] = []

    private init() {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "PersistedWalk"
        entity.managedObjectClassName = NSStringFromClass(PersistedWalk.self)

        func attribute(_ name: String, type: NSAttributeType) -> NSAttributeDescription {
            let description = NSAttributeDescription()
            description.name = name
            description.attributeType = type
            description.isOptional = true
            return description
        }

        entity.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("startDate", type: .dateAttributeType),
            attribute("endDate", type: .dateAttributeType),
            attribute("locationsData", type: .binaryDataAttributeType)
        ]
        model.entities = [entity]

        // HealthKit is only available to the iOS companion, and the Mac receives
        // GPX files through the share sheet. A local persistent store is the
        // reliable runtime choice here; initializing NSPersistentCloudKitContainer
        // can throw an uncaught CloudKit connection exception when the device has
        // no eligible iCloud account/container connection.
        container = NSPersistentContainer(name: "WalksGPX", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        container.loadPersistentStores { _, error in
            Task { @MainActor in
                self.loadError = error
                self.isReady = true
                for continuation in self.readinessContinuations {
                    continuation.resume()
                }
                self.readinessContinuations.removeAll()
                if let error {
                    let nsError = error as NSError
                    print("WalkStore failed to load: \(nsError), userInfo: \(nsError.userInfo)")
                }
            }
        }
    }

    func waitUntilReady() async {
        guard !isReady else { return }
        await withCheckedContinuation { continuation in
            readinessContinuations.append(continuation)
        }
    }

    func save(_ routes: [WalkRoute]) throws {
        guard !routes.isEmpty else { return }
        if let loadError { throw loadError }
        let context = container.viewContext
        try context.performAndWait {
            let request = PersistedWalk.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", routes.map(\.id))
            let existing = try context.fetch(request)
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for route in routes {
                let walk = byID[route.id] ?? PersistedWalk(context: context)
                walk.id = route.id
                walk.startDate = route.startDate
                walk.endDate = route.endDate
                walk.locationsData = try JSONEncoder().encode(route.locations)
            }
            if context.hasChanges { try context.save() }
        }
    }

    func delete(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        if let loadError { throw loadError }
        let context = container.viewContext
        try context.performAndWait {
            let request = PersistedWalk.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids)
            for walk in try context.fetch(request) {
                context.delete(walk)
            }
            if context.hasChanges { try context.save() }
        }
    }

    func fetchRoutes() -> [WalkRoute] {
        let request = PersistedWalk.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(PersistedWalk.startDate), ascending: false)]
        return ((try? container.viewContext.fetch(request)) ?? []).compactMap(\.route)
    }
}
