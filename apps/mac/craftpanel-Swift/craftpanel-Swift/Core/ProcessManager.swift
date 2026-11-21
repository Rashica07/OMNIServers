import Foundation
import Observation

/// Owns one `ServerRuntime` per server id. The Swift equivalent of
/// `process::ProcessManager` — minus the event-sink plumbing, since
/// SwiftUI observes `ServerRuntime` directly.
/// Not marked `@MainActor` at the class level, deliberately. On this
/// toolchain a `@MainActor @Observable` class traps in
/// `swift_task_deinitOnExecutorImpl` when its last reference is released
/// from off the main actor — a real `abort()`, reproduced and confirmed
/// from crash logs, not a hypothetical. Isolation is applied per-member
/// instead, which gives the same safety without the isolated-deinit
/// teardown path. Same reasoning applies to `ServerRuntime`.
@Observable
final class ProcessManager {
    @MainActor private var runtimes: [UUID: ServerRuntime] = [:]

    nonisolated init() {}

    /// Explicitly `nonisolated`, same reason as `ServerRuntime`'s: a
    /// stored `@MainActor` property is enough to make Swift synthesize an
    /// isolated deinit, which traps on this toolchain when the last
    /// reference is released off the main actor. Nothing needs cleaning
    /// up here anyway — runtimes tear themselves down when their child
    /// process exits.
    nonisolated deinit {}

    /// Never returns nil — a server with no runtime yet gets a fresh
    /// stopped one, matching `ProcessManager::shared_for`'s
    /// entry-or-default behavior.
    @MainActor func runtime(for id: UUID) -> ServerRuntime {
        if let existing = runtimes[id] { return existing }
        let fresh = ServerRuntime(serverID: id)
        runtimes[id] = fresh
        return fresh
    }

    @MainActor func isRunning(_ id: UUID) -> Bool {
        runtimes[id]?.isRunning ?? false
    }

    @MainActor var anyRunning: Bool {
        runtimes.values.contains { $0.isRunning }
    }

    @MainActor var runningCount: Int {
        runtimes.values.count { $0.isRunning }
    }

    /// On launch: re-adopt every server that has a live session file, so a
    /// OMNIServers restart never orphans a running server or mislabels it
    /// "external". Mirrors `ProcessManager::adopt_all`.
    @MainActor func adoptAll(records: [ServerRecord]) {
        for rec in records {
            let dir = URL(fileURLWithPath: rec.path)
            guard let session = ServerSession.read(dir: dir) else { continue }
            if ServerSession.serverAlive(pid: session.pid, startedAt: session.startedAt) {
                runtime(for: rec.id).adopt(record: rec, session: session)
            } else {
                ServerSession.clear(dir: dir)
            }
        }
    }

    @MainActor func start(_ record: ServerRecord, force: Bool = false) throws {
        try runtime(for: record.id).start(record: record, force: force)
    }

    @MainActor func stop(_ id: UUID) throws {
        try runtime(for: id).stop()
    }

    @MainActor func forceKill(_ id: UUID) throws {
        try runtime(for: id).forceKill()
    }

    /// Stop everything still running — called from `AppDelegate` on quit
    /// so a server isn't orphaned.
    @MainActor func shutdownAll() {
        for rt in runtimes.values where rt.isRunning && rt.snapshot.status != .stopping {
            try? rt.stop()
        }
    }

    /// Run `body` (a backup/snapshot) with the world flushed and autosave
    /// paused; autosave is always turned back on afterwards.
    @MainActor func withSavesPaused<T: Sendable>(_ id: UUID, _ body: @Sendable () async throws -> T) async throws -> T {
        let rt = runtime(for: id)
        let paused = await rt.pauseSaves()
        defer { if paused { rt.resumeSaves() } }
        return try await body()
    }

    @MainActor func forceKillAll() {
        for rt in runtimes.values where rt.isRunning {
            try? rt.forceKill()
        }
    }
}
