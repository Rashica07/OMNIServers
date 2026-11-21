import Foundation

/// Per-server automation: auto-restart on crash (bounded + backoff), a
/// daily restart with an in-game countdown, timed commands, and a backup
/// on stop. Direct port of `schedule.rs`'s `Schedule`/`TimedCommand`.
///
/// Config lives as JSON on `ServerRecord.scheduleJSON` — the SwiftData
/// equivalent of the Rust side's `settings` table row keyed
/// `schedule.<id>`. The actual tick engine is `Scheduler`.
nonisolated struct TimedCommand: Codable, Sendable, Equatable, Identifiable {
    var id: String { at + "@" + command }
    /// "HH:MM" local
    var at: String
    var command: String
}

nonisolated struct Schedule: Codable, Sendable, Equatable {
    var restartOnCrash: Bool = false
    /// give up after this many crash-restarts inside the window (default 3)
    var maxCrashRestarts: UInt32 = 0
    /// "HH:MM" local — start the server once a day at this time, if it
    /// isn't already running. Pair with "Stay awake on power" in
    /// OMNIServers Settings so the Mac is actually up to notice.
    var scheduledStart: String?
    /// "HH:MM" local — restart once a day at this time
    var dailyRestart: String?
    /// seconds of in-game warning before the daily restart (default 60)
    var restartWarningSecs: UInt32 = 0
    var timedCommands: [TimedCommand] = []
    /// commands sent once each time the server finishes starting (e.g. `gamerule keepInventory true`).
    var onStartCommands: [String]?
    /// take a backup (trigger = "scheduled") every time the server stops cleanly
    var backupOnStop: Bool = false
    /// also take a backup every N hours while the server is running, on
    /// top of (not instead of) `backupOnStop`. `nil`/`0` = off.
    var intervalBackupHours: UInt32?
    /// minutes between automatic hardlink Time Machine snapshots while the
    /// server is running. `nil`/`0` = off. Floored at 5 min.
    var snapshotIntervalMins: UInt32?
    /// keep every snapshot from within this many hours (default 24 if unset/0)
    var snapshotKeepRecentHours: UInt32 = 0
    /// beyond the recent window, thin to one snapshot per day for this
    /// many days (default 30 if unset/0)
    var snapshotKeepDailyDays: UInt32 = 0

    var isDefault: Bool {
        !restartOnCrash
            && scheduledStart == nil
            && dailyRestart == nil
            && timedCommands.isEmpty
            && (onStartCommands ?? []).isEmpty
            && !backupOnStop
            && (intervalBackupHours ?? 0) == 0
            && (snapshotIntervalMins ?? 0) == 0
    }

    var maxRestarts: UInt32 { maxCrashRestarts == 0 ? 3 : maxCrashRestarts }
    var warningSecs: UInt32 { restartWarningSecs == 0 ? 60 : restartWarningSecs }
    var snapshotRecentHours: UInt32 { snapshotKeepRecentHours == 0 ? 24 : snapshotKeepRecentHours }
    var snapshotDailyDays: UInt32 { snapshotKeepDailyDays == 0 ? 30 : snapshotKeepDailyDays }
}

nonisolated enum ScheduleStore {
    static func read(_ server: ServerRecord) -> Schedule {
        guard let json = server.scheduleJSON, let data = json.data(using: .utf8) else { return Schedule() }
        return (try? JSONDecoder().decode(Schedule.self, from: data)) ?? Schedule()
    }

    /// Validates every "HH:MM" field, then writes. Mirrors `schedule::write`.
    @discardableResult
    static func write(_ server: ServerRecord, _ schedule: Schedule) throws -> Schedule {
        for tc in schedule.timedCommands {
            guard parseHHMM(tc.at) != nil else {
                throw RconServiceError.message("bad time '\(tc.at)': use HH:MM")
            }
        }
        if let t = schedule.dailyRestart, !t.isEmpty {
            guard parseHHMM(t) != nil else { throw RconServiceError.message("bad time '\(t)': use HH:MM") }
        }
        if let t = schedule.scheduledStart, !t.isEmpty {
            guard parseHHMM(t) != nil else { throw RconServiceError.message("bad time '\(t)': use HH:MM") }
        }
        let data = try JSONEncoder().encode(schedule)
        server.scheduleJSON = String(data: data, encoding: .utf8)
        return schedule
    }

    static func parseHHMM(_ s: String) -> (Int, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return (h >= 0 && h < 24 && m >= 0 && m < 60) ? (h, m) : nil
    }
}
