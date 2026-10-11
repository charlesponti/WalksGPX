import Foundation

enum SyncMessaging {
    static func starting(backfillingHistory: Bool, queuedRouteCount: Int) -> String {
        if backfillingHistory {
            return "Scanning your full HealthKit walking history…"
        }
        if queuedRouteCount > 0 {
            return "Loading \(queuedRouteCount) saved walks to repair…"
        }
        return "Checking HealthKit…"
    }

    static func foundWorkouts(_ count: Int) -> String {
        guard count > 0 else { return "No new walking workouts found." }
        return "Found \(count) walking workout\(count == 1 ? "" : "s"). Reading GPS routes…"
    }

    static func completed(savedRouteCount: Int, workoutCount: Int, pendingRouteCount: Int) -> String {
        if savedRouteCount == 0, workoutCount > 0 {
            return "HealthKit returned \(workoutCount) workouts but no GPS routes. In Health, open Apps and Services > Walks GPX and allow Workouts and Workout Routes. If both are enabled, those workouts may not contain GPS routes."
        }
        if savedRouteCount == 0 {
            return "No walking workouts are visible. Check Health access for Workouts and Workout Routes, then sync again."
        }
        if pendingRouteCount > 0 {
            return "Saved \(savedRouteCount) GPS routes. \(pendingRouteCount) workouts still have no readable route; check Health access for Workout Routes."
        }
        return "Saved \(savedRouteCount) GPS route\(savedRouteCount == 1 ? "" : "s")."
    }
}
