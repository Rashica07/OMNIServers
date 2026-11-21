import Foundation
import SwiftData

/// Per-server automation engine: auto-restart on crash (bounded +
/// backoff), a daily restart with an in-game countdown, timed stdin
/// commands, and backup/snapshot triggers. Direct port of `schedule.rs`'s
/// `Scheduler`/`tick()`.
///
/// A single `@MainActor` loop ticks every 15s and acts on every server —
/// same cadence as the Rust side's dedicated background thread. Every
/// action here (`ProcessManager.start/stop`, `ServerRuntime.writeStdin`)
/// is already `@MainActor`-isolated in this app, so a plain `Task.sleep`
/// loop does the job with no thread-hop needed; the actual zip/hardlink
/// work for backups and snapshots is still pushed onto a background task,
/// same reasoning as the Rust side's own `std::thread::spawn` in
/// `run_backup`/`run_snapshot`.
///
/// One deliberate behavior change from the Rust source: a crash-restart's
/// backoff delay runs in its own detached `Task` here instead of blocking
/// the tick loop with `std::thread::sleep` — so one server backing off
/// from a crash never delays another server's tick in the same pass.
@MainActor
final class Scheduler {
    private let container: ModelContainer
    private let processes: ProcessManager
    private var state: [UUID: DayState] = [:]
    private var running = false

    static let tickSeconds: UInt64 = 15
    static let crashWindowSeconds: TimeInterval = 900
    private static let defaultBackupKeep = 20

    private struct DayState {
        var dailyDone: Date?
        var startDone: Date?
        var cmdDone: [String: Date] = [:]
        var crashCount: UInt32 = 0
        var lastCrashSeen: Date = .distantPast
        var gaveUp = false
        var warned: Date?
        var lastStatus: ServerStatus?
        var lastIntervalBackup: Date = .distantPast
        var lastSnapshot: Date = .distantPast
    }

    init(container: ModelContainer, processes: ProcessManager) {
        self.container = container
        self.processes = processes
    }

    /// Idempotent — a second call is a no-op, since this is started once
    /// from the app's root `.task` and that `.task` can re-run.
    func start() {
        guard !running else { return }
        running = true
        Task { [weak self] in
            while let self, self.running {
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
                self.tick()
            }
        }
    }

    private func tick() {
        // mainContext (not a throwaway ModelContext): models captured by the
        // delayed restart tasks below must outlive this tick.
        let context = container.mainContext
        guard let servers = try? context.fetch(FetchDescriptor<ServerRecord>()) else { return }
        let now = Date()
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        for server in servers {
            let sch = ScheduleStore.read(server)
            if sch.isDefault { continue }

            let runtime = processes.runtime(for: server.id)
            let status = runtime.snapshot.status
            var ds = state[server.id] ?? DayState()

            // --- backup on stop (running/stopping -> stopped) ---
            let prev = ds.lastStatus
            ds.lastStatus = status
            if sch.backupOnStop,
               (prev == .running || prev == .stopping),
               status == .stopped {
                state[server.id] = ds
                console(server, "server stopped — taking a scheduled backup")
                runBackup(server: server, trigger: "on stop")
                continue
            }

            // --- on-start commands (once, when it becomes running) ---
            if status == .running, prev != .running, let cmds = sch.onStartCommands, !cmds.isEmpty {
                for c in cmds where !c.trimmingCharacters(in: .whitespaces).isEmpty {
                    try? runtime.writeStdin(c)
                    console(server, "ran start command: \(c)")
                }
            }

            // --- crash auto-restart ---
            if sch.restartOnCrash, status == .crashed {
                if now.timeIntervalSince(ds.lastCrashSeen) > Self.crashWindowSeconds {
                    ds.crashCount = 0
                    ds.gaveUp = false
                }
                if now.timeIntervalSince(ds.lastCrashSeen) > 5 {
                    ds.lastCrashSeen = now
                    if ds.crashCount < sch.maxRestarts {
                        ds.crashCount += 1
                        let n = ds.crashCount, max = sch.maxRestarts
                        state[server.id] = ds
                        console(server, "server crashed — restarting (\(n)/\(max))")
                        scheduleCrashRestart(server: server, afterSeconds: min(5 * UInt64(n), 60))
                        continue
                    } else if !ds.gaveUp {
                        ds.gaveUp = true
                        state[server.id] = ds
                        console(server, "server crashed \(sch.maxRestarts) times in 15 min — auto-restart disabled until it starts cleanly")
                        continue
                    }
                }
            }

            let isRunning = status == .running || status == .starting

            // --- scheduled start (only when it isn't already up) ---
            if !isRunning, let (h, m) = sch.scheduledStart.flatMap(ScheduleStore.parseHHMM) {
                let target = h * 60 + m
                if mins >= target, mins < target + 2, ds.startDone != day {
                    ds.startDone = day
                    state[server.id] = ds
                    console(server, "scheduled start")
                    do { try processes.start(server) }
                    catch { console(server, "scheduled start failed: \(error.localizedDescription)") }
                    continue
                }
            }

            // --- interval backup (independent of backupOnStop) ---
            if isRunning, let hours = sch.intervalBackupHours, hours > 0 {
                let interval = TimeInterval(hours) * 3600
                if now.timeIntervalSince(ds.lastIntervalBackup) >= interval {
                    ds.lastIntervalBackup = now
                    state[server.id] = ds
                    console(server, "scheduled backup (every \(hours)h)")
                    runBackup(server: server, trigger: "scheduled")
                    continue
                }
            }

            // --- Time Machine snapshot (independent of the zip backups above) ---
            if isRunning, let mins2 = sch.snapshotIntervalMins, mins2 > 0 {
                let interval = TimeInterval(max(mins2, 5)) * 60
                if now.timeIntervalSince(ds.lastSnapshot) >= interval {
                    ds.lastSnapshot = now
                    state[server.id] = ds
                    runSnapshot(server: server, keepRecentHours: sch.snapshotRecentHours, keepDailyDays: sch.snapshotDailyDays)
                    continue
                }
            }

            // --- daily restart with countdown ---
            if isRunning, let (h, m) = sch.dailyRestart.flatMap(ScheduleStore.parseHHMM) {
                let target = h * 60 + m
                let warnMin = target - Int((sch.warningSecs + 59) / 60)
                if mins >= warnMin, mins < target, ds.warned != day {
                    ds.warned = day
                    state[server.id] = ds
                    try? runtime.writeStdin("say Scheduled restart in ~\(max(target - mins, 1)) min")
                    continue
                } else if mins >= target, mins < target + 3, ds.dailyDone != day {
                    ds.dailyDone = day
                    state[server.id] = ds
                    console(server, "daily scheduled restart")
                    try? runtime.writeStdin("say Restarting now — back in a moment")
                    scheduleDailyRestart(server: server)
                    continue
                }
            }

            // --- timed commands (independent of daily restart above) ---
            if isRunning {
                for tc in sch.timedCommands {
                    guard let (th, tm) = ScheduleStore.parseHHMM(tc.at) else { continue }
                    let at = th * 60 + tm
                    if mins >= at, mins < at + 2, ds.cmdDone[tc.at] != day {
                        ds.cmdDone[tc.at] = day
                        state[server.id] = ds
                        try? runtime.writeStdin(tc.command)
                        console(server, "ran timed command: \(tc.command)")
                        break
                    }
                }
            }

            state[server.id] = ds
        }
    }

    // MARK: - Deferred actions

    /// Re-fetch by id at fire time: the server may have been removed (or its
    /// settings changed) during the delay.
    private func record(_ id: UUID) -> ServerRecord? {
        let d = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == id })
        return try? container.mainContext.fetch(d).first
    }

    private func scheduleCrashRestart(server: ServerRecord, afterSeconds: UInt64) {
        let id = server.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(afterSeconds))
            guard let self, let server = self.record(id) else { return }
            do { try self.processes.start(server) }
            catch { self.processes.runtime(for: id).push(.system, "[scheduler] auto-restart failed: \(error.localizedDescription)") }
        }
    }

    private func scheduleDailyRestart(server: ServerRecord) {
        let id = server.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            try? self.processes.stop(id)
            // wait for it to go down, then bring it back
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                if !self.processes.isRunning(id) { break }
            }
            guard let server = self.record(id) else { return }
            try? self.processes.start(server)
        }
    }

    private func runBackup(server: ServerRecord, trigger: String) {
        let dir = URL(fileURLWithPath: server.path)
        let id = server.id
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.processes.withSavesPaused(id) {
                    try await Task.detached(priority: .utility) {
                        _ = try BackupManager.backupNow(dir: dir, label: nil, trigger: trigger) { _ in }
                        BackupManager.applyRetention(dir: dir)
                    }.value
                }
                self.processes.runtime(for: id).push(.system, "[scheduler] scheduled backup done")
            } catch {
                self.processes.runtime(for: id).push(.system, "[scheduler] scheduled backup failed: \(error.localizedDescription)")
            }
        }
    }

    private func runSnapshot(server: ServerRecord, keepRecentHours: UInt32, keepDailyDays: UInt32) {
        let dir = URL(fileURLWithPath: server.path)
        let id = server.id
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.processes.withSavesPaused(id) {
                    try await Task.detached(priority: .utility) {
                        _ = try SnapshotManager.snapshotNow(dir: dir, trigger: "scheduled") { _ in }
                        SnapshotManager.prune(dir: dir, keepRecentHours: Int(keepRecentHours), keepDailyDays: Int(keepDailyDays))
                    }.value
                }
                self.processes.runtime(for: id).push(.system, "[scheduler] snapshot taken")
            } catch {
                self.processes.runtime(for: id).push(.system, "[scheduler] snapshot failed: \(error.localizedDescription)")
            }
        }
    }

    private func console(_ server: ServerRecord, _ msg: String) {
        processes.runtime(for: server.id).push(.system, "[scheduler] \(msg)")
    }
}
