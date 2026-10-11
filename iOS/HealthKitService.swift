import BackgroundTasks
import CoreLocation
import Foundation
import HealthKit

final class RouteBatchAccumulator: @unchecked Sendable {
    enum Update {
        case pending
        case completed([CLLocation])
        case failed(Error)
        case ignored
    }

    private let lock = NSLock()
    private var locations: [CLLocation] = []
    private var routesRemaining: Int
    private var isFinished = false

    init(routeCount: Int) {
        routesRemaining = routeCount
    }

    func receive(locations newLocations: [CLLocation]?, done: Bool, error: Error?) -> Update {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinished else { return .ignored }
        if let error {
            isFinished = true
            return .failed(error)
        }

        locations.append(contentsOf: newLocations ?? [])
        guard done else { return .pending }

        routesRemaining -= 1
        guard routesRemaining == 0 else { return .pending }
        isFinished = true
        return .completed(locations.sorted { $0.timestamp < $1.timestamp })
    }
}

enum RouteLocationConverter {
    static func points(from locations: [CLLocation]) -> [RouteLocation] {
        locations.compactMap { location in
            let point = RouteLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                elevation: location.altitude.isFinite ? location.altitude : nil,
                timestamp: location.timestamp
            )
            return point.isValidGPXPoint ? point : nil
        }
    }
}

@MainActor
final class HealthKitService: ObservableObject {
    @Published private(set) var walks: [WalkRoute] = []
    @Published private(set) var isLoading = false
    @Published private(set) var processedWalks = 0
    @Published private(set) var totalWalks = 0
    @Published private(set) var pendingRouteCount = 0
    @Published private(set) var hasConnected = false
    @Published var errorMessage: String?
    @Published private(set) var syncMessage: String?
    @Published private(set) var iCloudExportMessage: String?
    @Published private(set) var isExportingToICloud = false
    @Published private(set) var iCloudExportCompletedRouteCount = 0
    @Published private(set) var iCloudExportTotalRouteCount = 0

    var progress: Double {
        SyncProgress(processed: processedWalks, total: totalWalks).fraction
    }

    var iCloudExportProgress: Double? {
        guard iCloudExportTotalRouteCount > 0 else { return nil }
        return ICloudExportProgress(
            completedRoutes: iCloudExportCompletedRouteCount,
            totalRoutes: iCloudExportTotalRouteCount
        ).fraction
    }

    private let store = HKHealthStore()
    private let syncState: SyncStateStore
    private let healthDataAvailable: @Sendable () -> Bool
    private let requestAuthorization: @Sendable () async throws -> Void
    private let queryOverrides: HealthKitQueryOverrides?

    init(
        syncState: SyncStateStore = SyncStateStore(),
        presentationState: HealthKitPresentationState? = nil,
        healthDataAvailable: @escaping @Sendable () -> Bool = { HKHealthStore.isHealthDataAvailable() },
        requestAuthorization: @escaping @Sendable () async throws -> Void = {
            try await HKHealthStore().requestAuthorization(
                toShare: [],
                read: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
            )
        },
        queryOverrides: HealthKitQueryOverrides? = nil
    ) {
        self.syncState = syncState
        self.healthDataAvailable = healthDataAvailable
        self.requestAuthorization = requestAuthorization
        self.queryOverrides = queryOverrides
        hasConnected = syncState.hasConnected
        if let presentationState {
            apply(presentationState)
        }
    }

    private func apply(_ state: HealthKitPresentationState) {
        walks = state.walks
        isLoading = state.isLoading
        processedWalks = state.processedWalks
        totalWalks = state.totalWalks
        pendingRouteCount = state.pendingRouteCount
        hasConnected = state.hasConnected
        errorMessage = state.errorMessage
        syncMessage = state.syncMessage
        iCloudExportMessage = state.iCloudExportMessage
        isExportingToICloud = state.isExportingToICloud
        iCloudExportCompletedRouteCount = state.iCloudExportCompletedRouteCount
        iCloudExportTotalRouteCount = state.iCloudExportTotalRouteCount
    }

    func requestAccessAndLoad() async {
        guard healthDataAvailable() else {
            errorMessage = "Health data isn’t available on this device."
            return
        }

        do {
            try await requestAuthorization()
            syncState.markConnected()
            hasConnected = true
            _ = await syncIncrementally()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func syncIncrementally() async -> Bool {
        guard !isLoading else { return false }
        await WalkStore.shared.waitUntilReady()
        isLoading = true
        defer {
            isLoading = false
            BackgroundSyncScheduler.schedule()
        }

        do {
            errorMessage = nil
            let shouldBackfillHistory = syncState.needsFullHistoryBackfill
            let queuedRouteCount = syncState.pendingRouteIDs.count
            totalWalks = queuedRouteCount
            processedWalks = 0
            syncMessage = SyncMessaging.starting(
                backfillingHistory: shouldBackfillHistory,
                queuedRouteCount: queuedRouteCount
            )
            let pendingWorkouts = try await fetchPendingWorkouts()
            let historicalWorkouts = shouldBackfillHistory ? try await fetchAllWalkingWorkouts() : []
            let result = try await fetchWorkoutChanges()
            var workoutsByID: [UUID: HKWorkout] = [:]
            for workout in pendingWorkouts + historicalWorkouts {
                workoutsByID[workout.uuid] = workout
            }
            for workout in result.added {
                workoutsByID[workout.uuid] = workout
            }

            let deletedIDs = Set(result.deleted.map(\.uuid))
            var pendingRouteIDs = syncState.pendingRouteIDs.subtracting(deletedIDs)
            let workouts = workoutsByID.values.filter { !deletedIDs.contains($0.uuid) }.sorted { $0.startDate < $1.startDate }

            totalWalks = max(workouts.count, queuedRouteCount)
            processedWalks = 0
            syncMessage = SyncMessaging.foundWorkouts(workouts.count)

            let maxConcurrentRouteReads = 4
            var exportBatch: [WalkRoute] = []
            var cloudBatchPublishingAvailable = true
            try await withThrowingTaskGroup(of: (UUID, WalkRoute?).self) { group in
                var nextWorkoutIndex = 0
                let initialCount = min(maxConcurrentRouteReads, workouts.count)

                for _ in 0..<initialCount {
                    let workout = workouts[nextWorkoutIndex]
                    nextWorkoutIndex += 1
                    group.addTask {
                        (workout.uuid, try await self.fetchRoute(for: workout))
                    }
                }

                while let (workoutID, route) = try await group.next() {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        throw CancellationError()
                    }
                    if let route {
                        try WalkStore.shared.save([route])
                        pendingRouteIDs.remove(workoutID)
                        exportBatch.append(route)
                        if exportBatch.count >= ICloudGPXPublisher.publicationBatchSize {
                            if cloudBatchPublishingAvailable {
                                cloudBatchPublishingAvailable = await publishICloudBatch(exportBatch)
                            }
                            exportBatch.removeAll(keepingCapacity: true)
                        }
                    } else {
                        pendingRouteIDs.insert(workoutID)
                    }
                    processedWalks += 1

                    if nextWorkoutIndex < workouts.count {
                        let workout = workouts[nextWorkoutIndex]
                        nextWorkoutIndex += 1
                        group.addTask {
                            (workout.uuid, try await self.fetchRoute(for: workout))
                        }
                    }
                }
            }

            if !exportBatch.isEmpty, cloudBatchPublishingAvailable {
                _ = await publishICloudBatch(exportBatch)
            }

            try WalkStore.shared.delete(ids: deletedIDs)
            syncState.save(anchor: result.anchor, pendingRouteIDs: pendingRouteIDs)
            if shouldBackfillHistory {
                syncState.markFullHistoryBackfillComplete()
            }
            pendingRouteCount = pendingRouteIDs.count
            walks = WalkStore.shared.fetchRoutes()
            syncMessage = SyncMessaging.completed(
                savedRouteCount: walks.count,
                workoutCount: workouts.count,
                pendingRouteCount: pendingRouteCount
            )
            await reconcileICloudExports(routes: walks)
            return true
        } catch is CancellationError {
            syncMessage = "Sync paused. Saved routes will be kept and retried."
            return false
        } catch {
            errorMessage = error.localizedDescription
            syncMessage = "Sync failed: \(error.localizedDescription)"
            return false
        }
    }

    func loadWalks() async {
        _ = await syncIncrementally()
    }

    func importFullHistory() async {
        guard !isLoading else { return }
        syncState.requestFullHistoryBackfill()
        _ = await syncIncrementally()
    }

    func loadStoredWalks() {
        walks = WalkStore.shared.fetchRoutes()
        if syncState.needsRouteBatchRepair, syncState.anchor != nil {
            syncState.addPendingRouteIDs(Set(walks.map(\.id)))
            syncState.markRouteBatchRepairComplete()
        }
        let incompleteRouteIDs = Set(walks.filter { $0.locations.count < 2 }.map(\.id))
        syncState.addPendingRouteIDs(incompleteRouteIDs)
        pendingRouteCount = syncState.pendingRouteIDs.count
    }

    func retryICloudExport() async {
        await WalkStore.shared.waitUntilReady()
        await reconcileICloudExports(routes: WalkStore.shared.fetchRoutes())
    }

    private func publishICloudBatch(_ routes: [WalkRoute]) async -> Bool {
        isExportingToICloud = true
        iCloudExportMessage = "Preparing routes for iCloud Drive…"
        do {
            _ = try await ICloudGPXPublisher.shared.publishBatch(routes)
            iCloudExportMessage = "Preparing \(routes.count) route files for iCloud Drive…"
            isExportingToICloud = false
            return true
        } catch {
            iCloudExportMessage = "iCloud export will retry. Walks are safe on this iPhone. \(error.localizedDescription)"
            isExportingToICloud = false
            return false
        }
    }

    private func reconcileICloudExports(routes: [WalkRoute]) async {
        isExportingToICloud = true
        iCloudExportCompletedRouteCount = 0
        iCloudExportTotalRouteCount = routes.count
        iCloudExportMessage = "Updating the iCloud Drive walk folder…"
        do {
            let report = try await ICloudGPXPublisher.shared.reconcile(routes: routes) { [weak self] progress in
                Task { @MainActor in
                    self?.iCloudExportCompletedRouteCount = progress.completedRoutes
                    self?.iCloudExportTotalRouteCount = progress.totalRoutes
                    self?.iCloudExportMessage = "Updating the iCloud Drive walk folder…"
                }
            }
            iCloudExportCompletedRouteCount = report.routeCount
            iCloudExportTotalRouteCount = report.routeCount
            if report.allFilesUploaded {
                iCloudExportMessage = "\(report.routeCount) walks are available in iCloud Drive · Walks GPX."
            } else {
                iCloudExportMessage = "\(report.routeCount) walks are in the iCloud Drive folder; upload is still in progress."
            }
        } catch {
            iCloudExportMessage = "iCloud export needs a retry. Walks are safe on this iPhone. \(error.localizedDescription)"
        }
        isExportingToICloud = false
    }

    private func fetchWorkoutChanges() async throws -> (added: [HKWorkout], deleted: [HKDeletedObject], anchor: HKQueryAnchor) {
        if let queryOverrides {
            return try await queryOverrides.workoutChanges()
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(added: [HKWorkout], deleted: [HKDeletedObject], anchor: HKQueryAnchor), Error>) in
            let predicate = HKQuery.predicateForWorkouts(with: .walking)
            let query = HKAnchoredObjectQuery(
                type: .workoutType(),
                predicate: predicate,
                anchor: syncState.anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, anchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let anchor else {
                    continuation.resume(throwing: SyncError.missingAnchor)
                    return
                }
                continuation.resume(returning: (
                    samples as? [HKWorkout] ?? [],
                    deleted ?? [],
                    anchor
                ))
            }
            store.execute(query)
        }
    }

    private func fetchPendingWorkouts() async throws -> [HKWorkout] {
        if let queryOverrides {
            return try await queryOverrides.pendingWorkouts()
        }
        let pendingIDs = syncState.pendingRouteIDs
        guard !pendingIDs.isEmpty else { return [] }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let predicate = HKQuery.predicateForObjects(with: pendingIDs)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchAllWalkingWorkouts() async throws -> [HKWorkout] {
        if let queryOverrides {
            return try await queryOverrides.allWalkingWorkouts()
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: HKQuery.predicateForWorkouts(with: .walking),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchRoute(for workout: HKWorkout) async throws -> WalkRoute? {
        if let queryOverrides {
            return try await queryOverrides.route(workout)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WalkRoute?, Error>) in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [store] _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let routes = (samples as? [HKWorkoutRoute]) ?? []
                guard !routes.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let accumulator = RouteBatchAccumulator(routeCount: routes.count)

                for route in routes {
                    let routeQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, routeError in
                        switch accumulator.receive(locations: locations, done: done, error: routeError) {
                        case .pending, .ignored:
                            return
                        case .failed(let error):
                            continuation.resume(throwing: error)
                        case .completed(let locations):
                            let points = RouteLocationConverter.points(from: locations)
                            guard points.count >= 2 else {
                                continuation.resume(returning: nil)
                                return
                            }
                            continuation.resume(returning: WalkRoute(id: workout.uuid, startDate: workout.startDate, endDate: workout.endDate, locations: points))
                        }
                    }
                    store.execute(routeQuery)
                }
            }
            store.execute(query)
        }
    }
}

struct HealthKitQueryOverrides {
    let workoutChanges: () async throws -> (added: [HKWorkout], deleted: [HKDeletedObject], anchor: HKQueryAnchor)
    let pendingWorkouts: () async throws -> [HKWorkout]
    let allWalkingWorkouts: () async throws -> [HKWorkout]
    let route: (HKWorkout) async throws -> WalkRoute?
}

struct HealthKitPresentationState {
    var walks: [WalkRoute] = []
    var isLoading = false
    var processedWalks = 0
    var totalWalks = 0
    var pendingRouteCount = 0
    var hasConnected = false
    var errorMessage: String?
    var syncMessage: String?
    var iCloudExportMessage: String?
    var isExportingToICloud = false
    var iCloudExportCompletedRouteCount = 0
    var iCloudExportTotalRouteCount = 0
}

enum SyncError: LocalizedError {
    case missingAnchor

    var errorDescription: String? {
        "HealthKit did not return a sync anchor."
    }
}

@MainActor
enum BackgroundSyncScheduler {
    static let taskIdentifier = "io.ponti.walksgpx.refresh"

    static func register(using healthKit: HealthKitService) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            var syncTask: Task<Void, Never>?
            task.expirationHandler = {
                syncTask?.cancel()
            }
            syncTask = Task { @MainActor in
                let success = await healthKit.syncIncrementally()
                task.setTaskCompleted(success: success)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
