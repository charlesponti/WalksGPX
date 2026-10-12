import Foundation
import HealthKit

struct SyncProgress: Equatable {
    let processed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(processed) / Double(total)))
    }
}

struct SyncProgressDisplay: Equatable {
    let detail: String
    let fraction: Double?

    init(processed: Int, total: Int) {
        guard total > 0 else {
            detail = "Checking"
            fraction = nil
            return
        }
        detail = "\(processed) of \(total)"
        fraction = SyncProgress(processed: processed, total: total).fraction
    }
}

private struct PersistedSyncState: Codable {
    var anchorData: Data?
    var pendingRouteIDs: Set<UUID>
    var lastSyncDate: Date?
    var pendingICloudRouteIDs: Set<UUID>?
    var pendingICloudDeletionIDs: Set<UUID>?
}

final class SyncStateStore {
    private let defaults: UserDefaults
    private let stateKey = "healthKit.syncState"
    private let anchorKey = "healthKit.workoutAnchor"
    private let lastSyncKey = "healthKit.lastSyncDate"
    private let connectedKey = "healthKit.hasConnected"
    private let routeRepairKey = "healthKit.routeBatchRepair.v1"
    private let workoutMetadataBackfillKey = "healthKit.workoutMetadataBackfill.v1"
    private let initialICloudReconciliationKey = "icloud.initialReconciliation.v1"
    // v2 intentionally re-runs the historical import once. Earlier builds
    // created their Core Data description without a SQLite URL, so routes
    // could disappear after a restart even though the HealthKit anchor stayed.
    private let historyBackfillKey = "healthKit.fullHistoryBackfill.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var anchor: HKQueryAnchor? {
        guard let data = read().anchorData else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    var pendingRouteIDs: Set<UUID> {
        read().pendingRouteIDs
    }

    var lastSyncDate: Date? {
        read().lastSyncDate
    }

    var pendingICloudRouteIDs: Set<UUID> {
        read().pendingICloudRouteIDs ?? []
    }

    var pendingICloudDeletionIDs: Set<UUID> {
        read().pendingICloudDeletionIDs ?? []
    }

    var hasConnected: Bool {
        defaults.bool(forKey: connectedKey)
            || read().anchorData != nil
            || defaults.data(forKey: anchorKey) != nil
            || defaults.object(forKey: lastSyncKey) != nil
    }

    func markConnected() {
        defaults.set(true, forKey: connectedKey)
    }

    func save(anchor: HKQueryAnchor, pendingRouteIDs: Set<UUID> = [], at date: Date = .now) {
        guard let anchorData = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
            return
        }
        var state = read()
        state.anchorData = anchorData
        state.pendingRouteIDs = pendingRouteIDs
        state.lastSyncDate = date
        write(state)
        defaults.removeObject(forKey: anchorKey)
        defaults.removeObject(forKey: lastSyncKey)
    }

    func enqueueICloudRouteIDs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var state = read()
        state.pendingICloudRouteIDs = (state.pendingICloudRouteIDs ?? []).union(ids)
        state.pendingICloudDeletionIDs = (state.pendingICloudDeletionIDs ?? []).subtracting(ids)
        write(state)
    }

    func enqueueICloudDeletionIDs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var state = read()
        state.pendingICloudRouteIDs = (state.pendingICloudRouteIDs ?? []).subtracting(ids)
        state.pendingICloudDeletionIDs = (state.pendingICloudDeletionIDs ?? []).union(ids)
        write(state)
    }

    func acknowledgeICloudRouteIDs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var state = read()
        state.pendingICloudRouteIDs = (state.pendingICloudRouteIDs ?? []).subtracting(ids)
        write(state)
    }

    func acknowledgeICloudDeletionIDs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var state = read()
        state.pendingICloudDeletionIDs = (state.pendingICloudDeletionIDs ?? []).subtracting(ids)
        write(state)
    }

    var needsInitialICloudReconciliation: Bool {
        !defaults.bool(forKey: initialICloudReconciliationKey)
    }

    func markInitialICloudReconciliationComplete() {
        defaults.set(true, forKey: initialICloudReconciliationKey)
    }

    func addPendingRouteIDs(_ ids: Set<UUID>) {
        guard !ids.isEmpty, let anchor else { return }
        let state = read()
        save(anchor: anchor, pendingRouteIDs: state.pendingRouteIDs.union(ids), at: state.lastSyncDate ?? .now)
    }

    var needsRouteBatchRepair: Bool {
        !defaults.bool(forKey: routeRepairKey)
    }

    func markRouteBatchRepairComplete() {
        defaults.set(true, forKey: routeRepairKey)
    }

    var needsFullHistoryBackfill: Bool {
        !defaults.bool(forKey: historyBackfillKey)
    }

    func markFullHistoryBackfillComplete() {
        defaults.set(true, forKey: historyBackfillKey)
    }

    var needsWorkoutMetadataBackfill: Bool {
        !defaults.bool(forKey: workoutMetadataBackfillKey)
    }

    func markWorkoutMetadataBackfillComplete() {
        defaults.set(true, forKey: workoutMetadataBackfillKey)
    }

    func requestFullHistoryBackfill() {
        defaults.removeObject(forKey: historyBackfillKey)
    }

    func reset() {
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: anchorKey)
        defaults.removeObject(forKey: lastSyncKey)
        defaults.removeObject(forKey: connectedKey)
        defaults.removeObject(forKey: routeRepairKey)
        defaults.removeObject(forKey: workoutMetadataBackfillKey)
        defaults.removeObject(forKey: initialICloudReconciliationKey)
        defaults.removeObject(forKey: "healthKit.fullHistoryBackfill.v1")
        defaults.removeObject(forKey: historyBackfillKey)
    }

    private func read() -> PersistedSyncState {
        if let data = defaults.data(forKey: stateKey),
           let state = try? JSONDecoder().decode(PersistedSyncState.self, from: data) {
            return state
        }

        return PersistedSyncState(
            anchorData: defaults.data(forKey: anchorKey),
            pendingRouteIDs: [],
            lastSyncDate: defaults.object(forKey: lastSyncKey) as? Date,
            pendingICloudRouteIDs: [],
            pendingICloudDeletionIDs: []
        )
    }

    private func write(_ state: PersistedSyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }
}
