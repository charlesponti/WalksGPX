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
    @Published private(set) var isSyncInProgress = false
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
    @Published private(set) var savedWalkCount = 0
    @Published private(set) var savedRouteCount = 0

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
    private let walkStore: WalkStore
    private let syncState: SyncStateStore
    private let healthDataAvailable: @Sendable () -> Bool
    private let requestAuthorization: @Sendable () async throws -> Void
    private let queryOverrides: HealthKitQueryOverrides?
    private let iCloudReconciliationOverride: (@MainActor () async -> Void)?
    private let iCloudPublisher: ICloudGPXPublisher
    private var isReconcilingICloud = false
    private var iCloudReconciliationRequestedAgain = false
    private var iCloudRepairRequested = false

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
        queryOverrides: HealthKitQueryOverrides? = nil,
        iCloudReconciliationOverride: (@MainActor () async -> Void)? = nil,
        iCloudPublisher: ICloudGPXPublisher = .shared,
        walkStore: WalkStore = .shared
    ) {
        self.syncState = syncState
        self.healthDataAvailable = healthDataAvailable
        self.requestAuthorization = requestAuthorization
        self.queryOverrides = queryOverrides
        self.iCloudReconciliationOverride = iCloudReconciliationOverride
        self.iCloudPublisher = iCloudPublisher
        self.walkStore = walkStore
        hasConnected = syncState.hasConnected
        if let presentationState {
            apply(presentationState)
        }
    }

    private func apply(_ state: HealthKitPresentationState) {
        isSyncInProgress = state.isSyncInProgress
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
        savedWalkCount = state.savedWalkCount
        savedRouteCount = state.savedRouteCount
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
    func syncIncrementally(retryKnownUnavailableRoutes: Bool = false) async -> Bool {
        guard !isSyncInProgress else { return false }
        isSyncInProgress = true
        isLoading = true
        defer {
            isLoading = false
            isSyncInProgress = false
            BackgroundSyncScheduler.schedule()
        }
        await walkStore.waitUntilReady()

        do {
            errorMessage = nil
            let shouldBackfillHistory = syncState.needsFullHistoryBackfill
                || syncState.needsWorkoutMetadataBackfill
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

            let deletedIDs = Set(result.deleted)
            var pendingRouteIDs = syncState.pendingRouteIDs.subtracting(deletedIDs)
            let workouts = workoutsByID.values.filter { !deletedIDs.contains($0.uuid) }.sorted { $0.startDate < $1.startDate }

            try await walkStore.saveWorkoutMetadata(workouts.map {
                WalkMetadata(id: $0.uuid, startDate: $0.startDate, endDate: $0.endDate)
            })
            let workoutIDs = Set(workouts.map(\.uuid))
            let routeReadCandidateIDs = try await walkStore.fetchRouteReadCandidateIDs(for: workoutIDs)
            let workoutsNeedingRouteRead = workouts.filter {
                retryKnownUnavailableRoutes
                    || pendingRouteIDs.contains($0.uuid)
                    || routeReadCandidateIDs.contains($0.uuid)
            }

            totalWalks = max(workouts.count, queuedRouteCount)
            processedWalks = workouts.count - workoutsNeedingRouteRead.count
            syncMessage = SyncMessaging.foundWorkouts(workouts.count)

            let maxConcurrentRouteReads = 4
            try await withThrowingTaskGroup(of: (UUID, WalkRoute?).self) { group in
                var nextWorkoutIndex = 0
                let initialCount = min(maxConcurrentRouteReads, workoutsNeedingRouteRead.count)

                for _ in 0..<initialCount {
                    let workout = workoutsNeedingRouteRead[nextWorkoutIndex]
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
                        // Journal the export before writing route bytes so a
                        // process interruption can safely replay either side.
                        syncState.enqueueICloudRouteIDs([workoutID])
                        try await walkStore.saveRoutes([route])
                        pendingRouteIDs.remove(workoutID)
                    } else {
                        // The completed lookup produced no usable route. HealthKit
                        // read visibility is opaque, so this is not proof that no
                        // route exists; keep the summary and leave retry to an
                        // explicit historical repair instead of every launch.
                        pendingRouteIDs.remove(workoutID)
                        try await walkStore.markRoutesUnavailable(ids: [workoutID])
                    }
                    processedWalks += 1

                    if nextWorkoutIndex < workoutsNeedingRouteRead.count {
                        let workout = workoutsNeedingRouteRead[nextWorkoutIndex]
                        nextWorkoutIndex += 1
                        group.addTask {
                            (workout.uuid, try await self.fetchRoute(for: workout))
                        }
                    }
                }
            }

            syncState.enqueueICloudDeletionIDs(deletedIDs)
            try walkStore.delete(ids: deletedIDs)
            syncState.save(anchor: result.anchor, pendingRouteIDs: pendingRouteIDs)
            if syncState.needsFullHistoryBackfill {
                syncState.markFullHistoryBackfillComplete()
            }
            if syncState.needsWorkoutMetadataBackfill {
                syncState.markWorkoutMetadataBackfillComplete()
            }
            pendingRouteCount = pendingRouteIDs.count
            savedWalkCount = try await walkStore.fetchWalkCount()
            savedRouteCount = try await walkStore.fetchWalkCount(requiringGPSRoute: true)
            syncMessage = SyncMessaging.completed(
                savedRouteCount: savedRouteCount,
                workoutCount: workouts.count,
                pendingRouteCount: pendingRouteCount
            )
            // HealthKit is complete. The remaining full archive scan is the
            // separate iCloud Drive phase and must not be shown as walk sync.
            isLoading = false
            await reconcileICloudExports()
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
        _ = await syncIncrementally(retryKnownUnavailableRoutes: true)
    }

    func loadStoredWalks() async {
        await walkStore.waitUntilReady()
        do {
            savedWalkCount = try await walkStore.fetchWalkCount()
            savedRouteCount = try await walkStore.fetchWalkCount(requiringGPSRoute: true)
            if syncState.needsRouteBatchRepair, syncState.anchor != nil {
                var cursor: WalkRoutePageCursor?
                var repairIDs = Set<UUID>()
                repeat {
                    let page = try await walkStore.fetchRouteSummaryPage(
                        limit: 100,
                        before: cursor,
                        filter: WalkSearchFilter(requiresGPSRoute: false)
                    )
                    repairIDs.formUnion(page.summaries.map(\.id))
                    cursor = page.nextCursor
                    if !page.hasMore { break }
                } while true
                syncState.addPendingRouteIDs(repairIDs)
                syncState.markRouteBatchRepairComplete()
            }
        } catch {
            errorMessage = "Couldn't load saved walks: \(error.localizedDescription)"
        }
        pendingRouteCount = syncState.pendingRouteIDs.count
    }

    func retryICloudExport() async {
        await walkStore.waitUntilReady()
        await reconcileICloudExports()
    }

    func repairICloudExportFolder() async {
        await walkStore.waitUntilReady()
        await reconcileICloudExports(repairAll: true)
    }

    private func reconcileICloudExports(repairAll: Bool = false) async {
        guard !isReconcilingICloud else {
            // Coalesce a request that arrives during an export pass. A manual
            // repair remains explicit and is never downgraded to a queue retry.
            iCloudReconciliationRequestedAgain = true
            iCloudRepairRequested = iCloudRepairRequested || repairAll
            return
        }

        isReconcilingICloud = true
        var repairThisPass = repairAll
        repeat {
            iCloudReconciliationRequestedAgain = false
            let shouldRepair = repairThisPass || iCloudRepairRequested || syncState.needsInitialICloudReconciliation
            repairThisPass = false
            iCloudRepairRequested = false
            await performICloudReconciliation(repairAll: shouldRepair)
        } while iCloudReconciliationRequestedAgain
        isReconcilingICloud = false
    }

    private func performICloudReconciliation(repairAll: Bool) async {
        isExportingToICloud = true
        iCloudExportCompletedRouteCount = 0
        iCloudExportMessage = "Checking pending iCloud Drive changes…"
        if let iCloudReconciliationOverride {
            await iCloudReconciliationOverride()
            isExportingToICloud = false
            return
        }
        do {
            if repairAll {
                let deletionsCoveredByRepair = syncState.pendingICloudDeletionIDs
                let exportedIDs = try await rebuildICloudExportFolder()
                syncState.markInitialICloudReconciliationComplete()
                syncState.acknowledgeICloudRouteIDs(exportedIDs)
                syncState.acknowledgeICloudDeletionIDs(deletionsCoveredByRepair)
            } else if syncState.needsInitialICloudReconciliation {
                let routeIDs = try await walkStore.fetchAllRouteIDs()
                if try await iCloudPublisher.hasCompleteManifest(for: routeIDs) {
                    // Adopt an already-complete export without re-reading or
                    // reserializing its route payloads.
                    syncState.markInitialICloudReconciliationComplete()
                } else {
                    let deletionsCoveredByRepair = syncState.pendingICloudDeletionIDs
                    let exportedIDs = try await rebuildICloudExportFolder()
                    syncState.markInitialICloudReconciliationComplete()
                    syncState.acknowledgeICloudRouteIDs(exportedIDs)
                    syncState.acknowledgeICloudDeletionIDs(deletionsCoveredByRepair)
                }
            }

            try await processPendingICloudChanges()
        } catch {
            iCloudExportMessage = "iCloud export needs a retry. Walks are safe on this iPhone. \(error.localizedDescription)"
        }
        isExportingToICloud = false
    }

    private func rebuildICloudExportFolder() async throws -> Set<UUID> {
        let total = try await walkStore.fetchWalkCount(requiringGPSRoute: true)
        iCloudExportCompletedRouteCount = 0
        iCloudExportTotalRouteCount = total
        iCloudExportMessage = "Repairing the iCloud Drive walk folder…"
        var cursor: WalkRoutePageCursor?
        var entries: [ICloudExportManifestEntry] = []
        let pageSize = 64
        let writeBatchSize = 16

        repeat {
            let page = try await walkStore.fetchRouteSummaryPage(
                limit: pageSize,
                before: cursor,
                filter: WalkSearchFilter(requiresGPSRoute: true)
            )
            for start in stride(from: 0, to: page.summaries.count, by: writeBatchSize) {
                let end = min(start + writeBatchSize, page.summaries.count)
                let summaries = Array(page.summaries[start..<end])
                let routes = try await walkStore.fetchRoutes(ids: summaries.map(\.id))
                guard routes.count == summaries.count else { throw WalkStoreExportError.routeUnavailable }
                try await iCloudPublisher.writeReconciliationBatch(routes)
                entries.append(contentsOf: routes.map(ICloudExportManifestEntry.init(route:)))
                iCloudExportCompletedRouteCount += routes.count
            }
            cursor = page.nextCursor
            if !page.hasMore { break }
        } while true

        let report = try await iCloudPublisher.finishReconciliation(entries)
        iCloudExportCompletedRouteCount = report.routeCount
        iCloudExportTotalRouteCount = report.routeCount
        iCloudExportMessage = "Repaired the iCloud Drive folder with \(report.routeCount) walks."
        return Set(entries.map(\.id))
    }

    private func processPendingICloudChanges() async throws {
        let routeIDs = syncState.pendingICloudRouteIDs
        let deletedIDs = syncState.pendingICloudDeletionIDs
        let total = routeIDs.count + deletedIDs.count
        guard total > 0 else {
            if iCloudExportTotalRouteCount == 0 {
                iCloudExportMessage = "No pending iCloud Drive changes."
            }
            return
        }
        iCloudExportCompletedRouteCount = 0
        iCloudExportTotalRouteCount = total

        if !deletedIDs.isEmpty {
            try await iCloudPublisher.removeRoutes(ids: deletedIDs)
            syncState.acknowledgeICloudDeletionIDs(deletedIDs)
            iCloudExportCompletedRouteCount += deletedIDs.count
        }

        let batchSize = 16
        let orderedRouteIDs = routeIDs.sorted { $0.uuidString < $1.uuidString }
        for start in stride(from: 0, to: orderedRouteIDs.count, by: batchSize) {
            let end = min(start + batchSize, orderedRouteIDs.count)
            let ids = Array(orderedRouteIDs[start..<end])
            let routes = try await walkStore.fetchRoutes(ids: ids)
            guard routes.count == ids.count else { throw WalkStoreExportError.routeUnavailable }
            _ = try await iCloudPublisher.publishBatch(routes)
            syncState.acknowledgeICloudRouteIDs(Set(ids))
            iCloudExportCompletedRouteCount += routes.count
        }

        iCloudExportMessage = "Prepared \(total) changed walk\(total == 1 ? "" : "s") in iCloud Drive."
    }

    private func fetchWorkoutChanges() async throws -> (added: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor) {
        if let queryOverrides {
            return try await queryOverrides.workoutChanges()
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(added: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor), Error>) in
            let predicate = HKQuery.predicateForWorkouts(with: .walking)
            let completion = HealthKitQueryResult.workoutChangesHandler { continuation.resume(with: $0) }
            let query = HKAnchoredObjectQuery(
                type: .workoutType(),
                predicate: predicate,
                anchor: syncState.anchor,
                limit: HKObjectQueryNoLimit,
                resultsHandler: completion
            )
            store.execute(query)
        }
    }

    private func fetchPendingWorkouts() async throws -> [HKWorkout] {
        let pendingIDs = syncState.pendingRouteIDs
        guard !pendingIDs.isEmpty else { return [] }
        if let queryOverrides {
            return try await queryOverrides.pendingWorkouts()
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let predicate = HKQuery.predicateForObjects(with: pendingIDs)
            let completion = HealthKitQueryResult.workoutsHandler { continuation.resume(with: $0) }
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil, resultsHandler: completion)
            store.execute(query)
        }
    }

    private func fetchAllWalkingWorkouts() async throws -> [HKWorkout] {
        if let queryOverrides {
            return try await queryOverrides.allWalkingWorkouts()
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let completion = HealthKitQueryResult.workoutsHandler { continuation.resume(with: $0) }
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: HKQuery.predicateForWorkouts(with: .walking),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)],
                resultsHandler: completion
            )
            store.execute(query)
        }
    }

    private func fetchRoute(for workout: HKWorkout) async throws -> WalkRoute? {
        if let queryOverrides {
            return try await queryOverrides.route(workout)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WalkRoute?, Error>) in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil,
                resultsHandler: HealthKitQueryResult.routeSamplesHandler(
                    workout: workout,
                    executeRouteQuery: { [store] index, routes, completion in
                        let routeQuery = HKWorkoutRouteQuery(route: routes[index]) { _, locations, done, routeError in
                            completion(locations, done, routeError)
                        }
                        store.execute(routeQuery)
                    },
                    complete: { continuation.resume(with: $0) }
                )
            )
            store.execute(query)
        }
    }
}

struct HealthKitQueryOverrides {
    let workoutChanges: () async throws -> (added: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor)
    let pendingWorkouts: () async throws -> [HKWorkout]
    let allWalkingWorkouts: () async throws -> [HKWorkout]
    let route: (HKWorkout) async throws -> WalkRoute?
}

enum HealthKitQueryResult {
    enum RouteBatchUpdate {
        case pending
        case failed(Error)
        case finished(WalkRoute?)
    }

    static func workoutChanges(
        samples: [HKSample]?,
        deleted: [HKDeletedObject]?,
        anchor: HKQueryAnchor?,
        error: Error?
    ) throws -> (added: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor) {
        if let error { throw error }
        guard let anchor else { throw SyncError.missingAnchor }
        return (samples as? [HKWorkout] ?? [], (deleted ?? []).map(\.uuid), anchor)
    }

    typealias WorkoutChanges = (added: [HKWorkout], deleted: [UUID], anchor: HKQueryAnchor)
    typealias WorkoutChangesHandler = @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void
    typealias WorkoutsHandler = @Sendable (HKSampleQuery, [HKSample]?, Error?) -> Void
    typealias RouteLocationsHandler = @Sendable ([CLLocation]?, Bool, Error?) -> Void
    typealias RouteSamplesHandler = @Sendable (HKSampleQuery, [HKSample]?, Error?) -> Void
    typealias RouteQueryExecutor = @Sendable (Int, [HKWorkoutRoute], @escaping RouteLocationsHandler) -> Void

    static func workoutChangesHandler(
        complete: @escaping @Sendable (Result<WorkoutChanges, Error>) -> Void
    ) -> WorkoutChangesHandler {
        { _, samples, deleted, anchor, error in
            do {
                complete(.success(try workoutChanges(samples: samples, deleted: deleted, anchor: anchor, error: error)))
            } catch {
                complete(.failure(error))
            }
        }
    }

    static func workoutsHandler(
        complete: @escaping @Sendable (Result<[HKWorkout], Error>) -> Void
    ) -> WorkoutsHandler {
        { _, samples, error in
            do {
                complete(.success(try workouts(samples: samples, error: error)))
            } catch {
                complete(.failure(error))
            }
        }
    }

    static func routeSamplesHandler(
        workout: HKWorkout,
        executeRouteQuery: @escaping RouteQueryExecutor,
        complete: @escaping @Sendable (Result<WalkRoute?, Error>) -> Void
    ) -> RouteSamplesHandler {
        { _, samples, error in
            do {
                guard let routes = try routeSamples(samples: samples, error: error) else {
                    complete(.success(nil))
                    return
                }
                runRouteQueries(
                    workout: workout,
                    routeCount: routes.count,
                    executeRouteQuery: { index, completion in
                        executeRouteQuery(index, routes, completion)
                    },
                    complete: complete
                )
            } catch {
                complete(.failure(error))
            }
        }
    }

    static func runRouteQueries(
        workout: HKWorkout,
        routeCount: Int,
        executeRouteQuery: @Sendable (Int, @escaping RouteLocationsHandler) -> Void,
        complete: @escaping @Sendable (Result<WalkRoute?, Error>) -> Void
    ) {
        guard routeCount > 0 else {
            complete(.success(nil))
            return
        }
        let accumulator = RouteBatchAccumulator(routeCount: routeCount)
        for index in 0..<routeCount {
            let handler = routeLocationsHandler(workout: workout, accumulator: accumulator, complete: complete)
            executeRouteQuery(index, handler)
        }
    }

    static func workouts(samples: [HKSample]?, error: Error?) throws -> [HKWorkout] {
        if let error { throw error }
        return samples as? [HKWorkout] ?? []
    }

    static func routeSamples(samples: [HKSample]?, error: Error?) throws -> [HKWorkoutRoute]? {
        if let error { throw error }
        let routes = samples as? [HKWorkoutRoute] ?? []
        return routes.isEmpty ? nil : routes
    }

    static func route(workout: HKWorkout, locations: [CLLocation]) -> WalkRoute? {
        let points = RouteLocationConverter.points(from: locations)
        guard points.count >= 2 else { return nil }
        return WalkRoute(
            id: workout.uuid,
            startDate: workout.startDate,
            endDate: workout.endDate,
            locations: points
        )
    }

    static func routeBatchUpdate(
        _ update: RouteBatchAccumulator.Update,
        workout: HKWorkout
    ) -> RouteBatchUpdate {
        switch update {
        case .pending, .ignored:
            .pending
        case .failed(let error):
            .failed(error)
        case .completed(let locations):
            .finished(route(workout: workout, locations: locations))
        }
    }

    static func routeLocationsHandler(
        workout: HKWorkout,
        accumulator: RouteBatchAccumulator,
        complete: @escaping @Sendable (Result<WalkRoute?, Error>) -> Void
    ) -> RouteLocationsHandler {
        { locations, done, error in
            switch routeBatchUpdate(
                accumulator.receive(locations: locations, done: done, error: error),
                workout: workout
            ) {
            case .pending:
                break
            case .failed(let error):
                complete(.failure(error))
            case .finished(let route):
                complete(.success(route))
            }
        }
    }
}

struct HealthKitPresentationState {
    var isSyncInProgress = false
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
    var savedWalkCount = 0
    var savedRouteCount = 0
}

private enum WalkStoreExportError: LocalizedError {
    case routeUnavailable

    var errorDescription: String? {
        "A saved route could not be loaded, so the iCloud Drive manifest was left unchanged. Retry the update."
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
