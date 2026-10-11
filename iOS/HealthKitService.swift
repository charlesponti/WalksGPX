import BackgroundTasks
import CoreLocation
import Foundation
import HealthKit

private final class RouteBatchAccumulator: @unchecked Sendable {
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

    var progress: Double {
        SyncProgress(processed: processedWalks, total: totalWalks).fraction
    }

    private let store = HKHealthStore()
    private let syncState: SyncStateStore

    init(syncState: SyncStateStore = SyncStateStore()) {
        self.syncState = syncState
        hasConnected = syncState.hasConnected
    }

    func requestAccessAndLoad() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "Health data isn’t available on this device."
            return
        }

        do {
            let workoutType = HKObjectType.workoutType()
            let routeType = HKSeriesType.workoutRoute()
            try await store.requestAuthorization(toShare: [], read: [workoutType, routeType])
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
            syncMessage = shouldBackfillHistory
                ? "Scanning your full HealthKit walking history…"
                : queuedRouteCount > 0
                ? "Loading \(queuedRouteCount) saved walks to repair…"
                : "Checking HealthKit…"
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
            syncMessage = workouts.isEmpty ? "No new walking workouts found." : "Found \(workouts.count) walking workout\(workouts.count == 1 ? "" : "s"). Reading GPS routes…"

            let maxConcurrentRouteReads = 4
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

            try WalkStore.shared.delete(ids: deletedIDs)
            syncState.save(anchor: result.anchor, pendingRouteIDs: pendingRouteIDs)
            if shouldBackfillHistory {
                syncState.markFullHistoryBackfillComplete()
            }
            pendingRouteCount = pendingRouteIDs.count
            walks = WalkStore.shared.fetchRoutes()
            if walks.isEmpty, !workouts.isEmpty {
                syncMessage = "HealthKit returned \(workouts.count) workouts but no GPS routes. In Health, open Apps and Services > Walks GPX and allow Workouts and Workout Routes. If both are enabled, those workouts may not contain GPS routes."
            } else if walks.isEmpty {
                syncMessage = "No walking workouts are visible. Check Health access for Workouts and Workout Routes, then sync again."
            } else if pendingRouteCount > 0 {
                syncMessage = "Saved \(walks.count) GPS routes. \(pendingRouteCount) workouts still have no readable route; check Health access for Workout Routes."
            } else {
                syncMessage = "Saved \(walks.count) GPS route\(walks.count == 1 ? "" : "s")."
            }
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

    private func fetchWorkoutChanges() async throws -> (added: [HKWorkout], deleted: [HKDeletedObject], anchor: HKQueryAnchor) {
        try await withCheckedThrowingContinuation { continuation in
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
        let pendingIDs = syncState.pendingRouteIDs
        guard !pendingIDs.isEmpty else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
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
        try await withCheckedThrowingContinuation { continuation in
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
        try await withCheckedThrowingContinuation { continuation in
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
                            let points = locations.map { location in
                            RouteLocation(
                                latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude,
                                elevation: location.altitude.isFinite ? location.altitude : nil,
                                timestamp: location.timestamp
                            )
                        }
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
