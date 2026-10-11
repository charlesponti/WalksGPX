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

private struct PersistedSyncState: Codable {
    var anchorData: Data?
    var pendingRouteIDs: Set<UUID>
    var lastSyncDate: Date?
}

final class SyncStateStore {
    private let defaults: UserDefaults
    private let stateKey = "healthKit.syncState"
    private let anchorKey = "healthKit.workoutAnchor"
    private let lastSyncKey = "healthKit.lastSyncDate"
    private let connectedKey = "healthKit.hasConnected"
    private let routeRepairKey = "healthKit.routeBatchRepair.v1"
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
        let state = PersistedSyncState(anchorData: anchorData, pendingRouteIDs: pendingRouteIDs, lastSyncDate: date)
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
        defaults.removeObject(forKey: anchorKey)
        defaults.removeObject(forKey: lastSyncKey)
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

    func requestFullHistoryBackfill() {
        defaults.removeObject(forKey: historyBackfillKey)
    }

    func reset() {
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: anchorKey)
        defaults.removeObject(forKey: lastSyncKey)
        defaults.removeObject(forKey: connectedKey)
        defaults.removeObject(forKey: routeRepairKey)
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
            lastSyncDate: defaults.object(forKey: lastSyncKey) as? Date
        )
    }
}
