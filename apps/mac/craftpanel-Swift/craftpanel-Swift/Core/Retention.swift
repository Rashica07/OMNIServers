import Foundation

/// "Keep everything recent, then thin older ones to one per day" — port of
/// `retention.rs`, shared by snapshots (always) and zip backups (
/// smart retention). Pure and clock-free (`now` is a parameter).
nonisolated enum Retention {
    struct PruneFailure: Equatable, Sendable {
        var id: String
        var message: String
    }

    struct Tiered: Codable, Equatable, Sendable {
        var recentHours: Int
        var dailyDays: Int
    }

    static func tieredKeepIDs(_ items: [(id: String, createdAt: Int64)], now: Int64,
                              recentHours: Int, dailyDays: Int) -> Set<String> {
        let recentCutoff = now - Int64(recentHours) * 3600
        let nowDay = floorDiv(now, 86400)
        var keep = Set<String>()
        var bestPerDay: [Int64: (id: String, createdAt: Int64)] = [:]
        for s in items {
            if s.createdAt >= recentCutoff { keep.insert(s.id); continue }
            let day = floorDiv(s.createdAt, 86400)
            if nowDay - day > Int64(dailyDays) { continue }
            if let cur = bestPerDay[day], cur.createdAt >= s.createdAt { continue }
            bestPerDay[day] = s
        }
        keep.formUnion(bestPerDay.values.map(\.id))
        return keep
    }

    static func protectedIDs(_ items: [(id: String, createdAt: Int64, pinned: Bool)]) -> Set<String> {
        guard !items.isEmpty else { return [] }
        let oldest = items.min { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }!
        let newest = items.max { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }!
        return Set(items.filter { $0.pinned }.map(\.id) + [oldest.id, newest.id])
    }

    static func log(_ failures: [PruneFailure], kind: String) {
        for failure in failures {
            fputs("OMNIServers \(kind) retention: failed to delete \(failure.id): \(failure.message)\n", stderr)
        }
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
