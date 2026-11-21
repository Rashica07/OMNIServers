import Foundation

/// One line of console output. Mirrors `process::LogLine`.
struct LogLine: Identifiable, Sendable, Equatable {
    let id: UInt64
    /// "stdout" | "stderr" | "system"
    let stream: Stream
    let text: String

    enum Stream: String, Sendable {
        case stdout, stderr, system
    }
}

/// Everything the UI needs to know about a server's process, in one value.
/// Mirrors `process::ProcSnapshot`.
struct ProcSnapshot: Sendable, Equatable {
    var serverID: UUID
    var status: ServerStatus = .stopped
    var pid: Int32?
    var exitCode: Int32?
    var startedAt: Date?
    var stopRequested: Bool = false
    /// Server bailed because the EULA hasn't been accepted.
    var needsEULA: Bool = false
    /// Re-adopted from a session file after a OMNIServers restart — it's
    /// ours, not "external", but the console isn't captured.
    var reattached: Bool = false
}

/// Live state for one server's process. `@Observable` rather than a
/// hand-rolled event sink (`process.rs`'s `EventSink` trait exists because
/// Rust has to bridge to Tauri's event system and to tests) — SwiftUI
/// observes this directly, no event plumbing needed. That's the native win
/// here: the Rust side emits `server:log`/`server:status` events that the
/// frontend subscribes to; SwiftUI just reads the properties.
/// Not marked `@MainActor` at the class level — see `ProcessManager`'s
/// comment for why (a `@MainActor @Observable` class traps on dealloc on
/// this toolchain). Isolation is applied per-member instead.
@Observable
final class ServerRuntime {
    nonisolated let serverID: UUID

    @MainActor private(set) var snapshot: ProcSnapshot

    /// Every status change goes through here so side services (the Playit agent) hear about it exactly once,
    /// whichever path changed it (start, stop, crash, re-adopt).
    @MainActor private func setStatus(_ new: ServerStatus) {
        let old = snapshot.status
        snapshot.status = new
        if old != new { PlayitCoordinator.shared.statusChanged(serverID: serverID, status: new) }
    }
    /// What kind of server this runtime last launched (decides the stop command).
    @MainActor private var runningType: ServerType = .vanilla
    /// Bounded ring buffer, same 500-line cap as `process::RING_CAPACITY` —
    /// a server that's been up for days would otherwise pin unbounded
    /// memory holding console scrollback nobody reads.
    @MainActor private(set) var lines: [LogLine] = []

    static let ringCapacity = 500
    static let chatCapacity = 300

    /// The server's name, for notifications ("Steve joined · MCServ").
    @MainActor var displayName = "Server"
    /// Players online, from join/leave lines (seeded over RCON on re-adopt).
    @MainActor private(set) var online: [String] = []
    /// Chat, joins/leaves and advancements for the Chat tab.
    @MainActor private(set) var chat: [ChatEntry] = []
    @MainActor private var chatSeq: UInt64 = 0
    @MainActor private var logTailTask: Task<Void, Never>?
    /// Matches `process::GRACEFUL_STOP_SECS`.
    static let gracefulStopSeconds: UInt64 = 25

    /// Console-only splash, printed by OMNIServers (not written to the
    /// server's own log). The Rust version linked the GitHub repo; left out
    /// here while that account is locked.
    static let banner = """
     ██████╗ ███╗   ███╗███╗   ██╗██╗
    ██╔═══██╗████╗ ████║████╗  ██║██║
    ██║   ██║██╔████╔██║██╔██╗ ██║██║
    ██║   ██║██║╚██╔╝██║██║╚██╗██║██║
    ╚██████╔╝██║ ╚═╝ ██║██║ ╚████║██║
     ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝
    ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ ███████╗
    ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗██╔════╝
    ███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝███████╗
    ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗╚════██║
    ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║███████║
    ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝╚══════╝
          This server was set up with OMNIServers
    """

    @MainActor private var seq: UInt64 = 0
    @MainActor private var process: Process?
    @MainActor private var stdinPipe: Pipe?
    /// Cancelled on stop so a lingering reader task can't outlive the process.
    @MainActor private var readerTasks: [Task<Void, Never>] = []
    /// Set when this runtime was re-adopted after a restart — we only have
    /// the pid, not a live `Process` handle, so `stop`/`kill`/`writeStdin`
    /// all need a separate path. Mirrors `Runtime.adopted_pid`.
    @MainActor private var adoptedPid: Int32?
    /// `(port, password)` — lets a fresh app instance ask an adopted
    /// server to stop over RCON once Batch B's `RconClient` exists. Until
    /// then, adopted stop always falls back to signalling the pid
    /// directly (see `stop()`'s doc comment).
    @MainActor private var rcon: (port: UInt16, password: String)?
    /// Cancelled when the adopted server's exit is noticed, or when this
    /// runtime transitions to owning a real child via a fresh `start()`.
    @MainActor private var adoptedMonitorTask: Task<Void, Never>?

    @MainActor init(serverID: UUID) {
        self.serverID = serverID
        self.snapshot = ProcSnapshot(serverID: serverID)
    }

    nonisolated deinit {
        // Deliberately `nonisolated` and doing nothing: the last reference
        // to a runtime can be dropped from anywhere (XCTest's memory
        // checker, a detached task), and any isolated deinit — even an
        // empty one — routes teardown through
        // `swift_task_deinitOnExecutorImpl`, which aborts the process on
        // this toolchain. Verified against a real crash log, not guessed.
        // Reader tasks don't need cancelling here anyway: they hold a
        // `weak self`, and the pipes they read close when the child
        // process exits, which ends their `AsyncStream` naturally.
    }

    @MainActor var isRunning: Bool {
        switch snapshot.status {
        case .starting, .running, .stopping: true
        case .stopped, .crashed, .unknown: false
        }
    }

    // MARK: - Console

    @MainActor func push(_ stream: LogLine.Stream, _ text: String) {
        seq += 1
        lines.append(LogLine(id: seq, stream: stream, text: text))
        let capacity = AppDefaults.lightMode ? 200 : Self.ringCapacity
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        if stream != .system, let event = LiveEvent.parse(text) { apply(event) }
    }

    // MARK: - Players & chat

    @MainActor private func apply(_ event: LiveEvent) {
        switch event {
        case .join(let p):
            if !online.contains(p) { online.append(p) }
            appendChat(.join, who: p, text: "joined the game")
        case .leave(let p):
            online.removeAll { $0 == p }
            appendChat(.leave, who: p, text: "left the game")
        case .chat(let p, let text): appendChat(.chat, who: p, text: text)
        case .broadcast(let who, let text): appendChat(.broadcast, who: who, text: text)
        case .advancement(let p, let t): appendChat(.advancement, who: p, text: t)
        }
        PlayerNotifier.shared.setOnline(serverID, count: online.count)
        PlayerNotifier.shared.handle(event, serverID: serverID, serverName: displayName, onlineCount: online.count)
    }

    @MainActor func appendChat(_ kind: ChatEntry.Kind, who: String, text: String, date: Date = Date()) {
        chatSeq += 1
        chat.append(ChatEntry(id: chatSeq, date: date, kind: kind, who: who, text: text))
        if chat.count > Self.chatCapacity { chat.removeFirst(chat.count - Self.chatCapacity) }
    }

    /// Fills the Chat tab from `logs/latest.log` the first time it opens.
    @MainActor func loadChatHistory(serverDir: URL) async {
        guard chat.isEmpty else { return }
        let past = await Task.detached { ChatHistory.load(serverDir: serverDir) }.value
        guard chat.isEmpty else { return }
        for e in past { appendChat(e.kind, who: e.who, text: e.text, date: e.date) }
    }

    @MainActor private func clearOnline() {
        online = []
        PlayerNotifier.shared.setOnline(serverID, count: 0)
    }

    /// Sends chat as "<name> message" to everyone in-game (tellraw), and
    /// shows it in the Chat tab — tellraw isn't echoed to the console.
    @MainActor func sendChat(_ message: String, as name: String, record: ServerRecord) async throws {
        let json = ChatHistory.tellrawJSON(name: name, message: message)
        if adoptedPid != nil {
            _ = try await RconService.shared.run(record: record, command: "tellraw @a \(json)")
        } else {
            try writeStdin("tellraw @a \(json)")
        }
        appendChat(.mine, who: name, text: message)
    }

    /// Flush the world to disk and pause autosave, so a backup/snapshot
    /// taken now isn't a torn copy of region files mid-write. Waits for the
    /// server's own "Saved the game" (bounded). No-op when not running or
    /// reattached without stdin (returns false; caller should still proceed).
    @MainActor func pauseSaves(timeout: Duration = .seconds(10)) async -> Bool {
        guard isRunning, adoptedPid == nil, snapshot.status == .running else { return false }
        let mark = seq
        do {
            try writeStdin("save-off")
            try writeStdin("save-all flush")
        } catch { return false }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lines.contains(where: { $0.id > mark && $0.text.contains("Saved the game") }) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    @MainActor func resumeSaves() {
        try? writeStdin("save-on")
    }

    @MainActor func clearConsole() {
        lines.removeAll()
    }

    // MARK: - Adopt (Batch A-2)

    /// Re-adopt a server whose session file says it's still alive after a
    /// OMNIServers restart — Swift port of `ProcessManager::adopt`. We only
    /// ever have its pid, not a `Process` handle, so live console output
    /// isn't captured; Stop, force-kill, and (once Batch B lands) RCON
    /// still work.
    @MainActor func adopt(record: ServerRecord, session: ServerSession) {
        snapshot.pid = session.pid
        snapshot.startedAt = Date(timeIntervalSince1970: TimeInterval(session.startedAt))
        snapshot.exitCode = nil
        snapshot.stopRequested = false
        snapshot.needsEULA = false
        snapshot.reattached = true
        adoptedPid = session.pid
        if let port = session.rconPort, let password = session.rconPassword {
            rcon = (port, password)
        } else {
            rcon = nil
        }
        setStatus(.running)
        displayName = record.name
        push(.system, "Reattached to this server (pid \(session.pid)) after a OMNIServers restart. "
            + "Following its log file for new output; commands go over RCON.")
        spawnAdoptedMonitor(record: record, pid: session.pid)
        spawnLogTail(dir: URL(fileURLWithPath: record.path))
        if rcon != nil {
            Task { [weak self] in
                guard let list = try? await RconService.shared.players(record: record), let self else { return }
                self.online = list.players
                PlayerNotifier.shared.setOnline(self.serverID, count: list.players.count)
            }
        }
    }

    /// Polls the pid every 2s — the same shape as `spawn_adopted_monitor`,
    /// since a re-adopted process gives us nothing to `waitpid`/select on.
    @MainActor private func spawnAdoptedMonitor(record: ServerRecord, pid: Int32) {
        let dir = URL(fileURLWithPath: record.path)
        adoptedMonitorTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                if !ServerSession.serverAlive(pid: pid) {
                    guard let self else { return }
                    self.snapshot.pid = nil
                    self.push(.system, "Reattached server exited.")
                    self.setStatus(.stopped)
                    self.clearOnline()
                    self.logTailTask?.cancel()
                    ServerSession.clear(dir: dir)
                    return
                }
            }
        }
    }

    /// A re-adopted server has no stdout pipe: follow its latest.log so
    /// the console, chat and join notifications keep working.
    @MainActor private func spawnLogTail(dir: URL) {
        logTailTask?.cancel()
        logTailTask = Task { [weak self] in
            var tail = LogTailer(serverDir: dir)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let new = tail.poll()
                guard let self, self.adoptedPid != nil else { return }
                for line in new { self.push(.stdout, line) }
            }
        }
    }

    // MARK: - Lifecycle

    /// `force` overrides another device's live lease on a folder-shared
    /// server — the caller (Settings' Share card) offers this as an
    /// explicit "Start Anyway" retry after the lease conflict error below.
    @MainActor func start(record: ServerRecord, adapter: MinecraftAdapter = MinecraftAdapter(), force: Bool = false) throws {
        guard !isRunning else {
            throw ProcessError.alreadyRunning
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProcessError.folderMissing(record.path)
        }
        // Starting again lets RCON back in (a stop had closed it so the server could exit).
        let sid = serverID
        Task { await RconService.shared.endShutdown(sid) }

        // Folder-shared server: take the advisory lease before we touch
        // the world. Throws "In use on X" if someone else holds it live
        // and `force` wasn't passed — matches `start_inner`'s own
        // claim-before-launch ordering exactly.
        let shareDir = URL(fileURLWithPath: record.path)
        if ShareLease.readShare(dir: shareDir) != nil {
            try ShareLease.claim(dir: shareDir, deviceID: ShareLease.thisDeviceID, force: force)
        }

        // Server still on the generic `java` (Apple's stub when no JDK is
        // registered)? Point it at a matching installed runtime first.
        if record.serverType.usesJava, let resolved = JavaProbe.autoResolve(javaPath: record.javaPath, mcVersion: record.mcVersion) {
            record.javaPath = resolved
            push(.system, "Using Java at \(resolved)")
        }

        let config = ServerConfig(
            path: URL(fileURLWithPath: record.path),
            launchTarget: record.launchTarget,
            javaPath: record.javaPath,
            ramMB: record.ramMB,
            serverType: record.serverType,
            jvmArgs: CrossplayManager.launchJvmArgs(serverDir: URL(fileURLWithPath: record.path), serverType: record.serverType, userArgs: record.jvmArgs)
        )
        // Forge/NeoForge servers launched via an args file read JVM flags
        // from `user_jvm_args.txt`, not argv — has to be written before
        // `startCommand` builds the `@user_jvm_args.txt` command line.
        MinecraftAdapter.ensureUserJVMArgs(config: config)
        runningType = record.serverType
        if record.serverType.isGame {
            guard GameServers.isPlatformSupported(record.serverType) else {
                throw ProcessError.launchFailed("\(record.serverType.label) has no server for macOS. Use a Windows or Linux PC.")
            }
            guard FileManager.default.fileExists(atPath: config.path.appending(path: record.launchTarget).path) else {
                throw ProcessError.launchFailed("The server program (\(record.launchTarget)) is missing from \(record.path).")
            }
            _ = GameServers.fix(type: record.serverType, dir: config.path, name: record.name)
        }
        let omniProc: Process? = record.serverType.isOmniHost ? OmniHostAdapter.startCommand(config: config) : nil
        if record.serverType.isOmniHost, omniProc == nil {
            throw ProcessError.launchFailed(OmniHostAdapter.missingEngineReason)
        }
        let proc = omniProc ?? (record.serverType.isGame ? GameServers.startCommand(config: config) : adapter.startCommand(config: config))

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe
        if record.serverType.isOmniHost {
            OmniHostAdapter.prepareFolder(config.path)
            push(.system, "Starting OMNIHost…")
        }

        // Fresh run: reset transient state, keep the ring so the previous
        // session stays visible until the first new line arrives — same
        // reasoning as `start_inner`'s comment on the Rust side.
        snapshot.exitCode = nil
        snapshot.stopRequested = false
        snapshot.needsEULA = false
        snapshot.reattached = false
        displayName = record.name
        clearOnline()

        do {
            try proc.run()
        } catch {
            throw ProcessError.launchFailed(
                !record.serverType.usesJava
                    ? "Failed to launch the server: \(error.localizedDescription)"
                    : "Failed to launch java (\(record.javaPath)): \(error.localizedDescription)"
            )
        }

        self.process = proc
        self.stdinPipe = stdinPipe
        // Real bug, found live on the Rust side and ported here as a
        // deliberate fix, not an afterthought: if this server was ever
        // reattached (`adopt()`) before — even a launch or two ago —
        // `adoptedPid` would stick around in this same runtime forever if
        // nothing ever cleared it. `stop()`/`forceKill()` check
        // `adoptedPid` first, so a later stop would keep targeting that
        // old, long-dead pid instead of the real child this exact call
        // just spawned — the real process would never get a correct kill
        // signal, and if the OS ever recycled that old pid onto some
        // unrelated process, a naive alive-check could even look like it
        // was still "gracefully" waiting on it. From here on this runtime
        // genuinely owns a fresh child process — that's the only truth
        // `stop`/`kill` should use.
        adoptedMonitorTask?.cancel()
        logTailTask?.cancel()
        adoptedMonitorTask = nil
        adoptedPid = nil
        rcon = nil

        snapshot.pid = proc.processIdentifier
        snapshot.startedAt = .now
        setStatus(.starting)
        push(.system, record.serverType.isGame ? GameServers.banner(game: record.serverType.label) : Self.banner) // "made with OMNIServers" splash (watermark.rs)
        push(.system, "Launched pid \(proc.processIdentifier): \(([proc.executableURL?.path ?? record.javaPath] + (proc.arguments ?? [])).joined(separator: " "))")

        readerTasks = [
            spawnReader(stdoutPipe, stream: .stdout, serverType: record.serverType, adapter: adapter),
            spawnReader(stderrPipe, stream: .stderr, serverType: record.serverType, adapter: adapter),
            spawnShareHeartbeat(dir: shareDir),
        ]
        let dir = URL(fileURLWithPath: record.path)
        spawnMonitor(proc, dir: dir)

        // Record the session so a OMNIServers restart re-adopts this
        // server instead of calling it "external".
        let (rconPort, rconPassword) = RconEndpointReader.read(dir: dir)
        ServerSession.write(dir: dir, session: ServerSession(
            pid: proc.processIdentifier,
            launcherPid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Int64(Date().timeIntervalSince1970),
            rconPort: rconPort,
            rconPassword: rconPassword
        ))
    }

    /// Graceful: send `stop` over stdin, then force-kill after a timeout.
    /// Mirrors `ProcessManager::stop`. An adopted server has no stdin pipe
    /// to write to, so it takes a separate path via `adoptedPid`.
    @MainActor func stop() throws {
        guard isRunning else {
            throw ProcessError.notRunning
        }
        if let pid = adoptedPid {
            try stopAdopted(pid: pid)
            return
        }
        guard let proc = process else {
            throw ProcessError.notRunning
        }
        snapshot.stopRequested = true
        setStatus(.stopping)
        push(.system, "Stop requested — sending 'stop'…")
        // Hang up our RCON connection first: the server waits for it to close before it will exit.
        let id = serverID
        Task { [weak self] in
            await RconService.shared.beginShutdown(id)
            try? self?.writeStdin(GameServers.stopCommand(self?.runningType ?? .vanilla))
        }

        // Watchdog: kill if it hasn't exited in time. Never trails off
        // silently — confirms the kill actually landed and says so either
        // way, the same hardening the Rust side got after a real
        // stuck-in-"Stopping" report.
        Task { [weak self] in
            for _ in 0..<(Self.gracefulStopSeconds * 2) {
                try? await Task.sleep(for: .milliseconds(500))
                if !proc.isRunning { return }
            }
            guard let self else { return }
            self.push(.system, "Graceful stop timed out — killing process.")
            proc.terminate()
            try? await Task.sleep(for: .milliseconds(800))
            if proc.isRunning {
                // SIGTERM didn't take — escalate to SIGKILL, which a
                // JVM wedged in shutdown can't ignore.
                kill(proc.processIdentifier, SIGKILL)
                // A big Java process can take several seconds to disappear; only report a problem if it really won't go.
                for _ in 0..<20 where proc.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
                if proc.isRunning {
                    self.push(.system, "pid \(proc.processIdentifier) is still around after a force-kill — it may need a manual kill.")
                }
            }
        }
    }

    /// Stop path for a re-adopted server — we only have its pid, no
    /// `Process` handle and no stdin pipe. Mirrors `ProcessManager::stop`'s
    /// adopted branch: try RCON `stop` first, and only fall back to
    /// signalling the pid directly if the RCON connection fails (no
    /// recorded endpoint, wrong password, server unreachable, etc).
    @MainActor private func stopAdopted(pid: Int32) throws {
        snapshot.stopRequested = true
        setStatus(.stopping)

        if let (port, password) = rcon {
            push(.system, "Stop requested — 'stop' over RCON…")
            let id = serverID
            Task { [weak self] in
                await RconService.shared.beginShutdown(id)      // close the pooled connection; "stop" goes over a fresh one
                do {
                    let client = try await RconClient.connect(host: "127.0.0.1", port: port, password: password)
                    _ = try? await client.command("save-all")
                    _ = try? await client.command("stop")
                    await client.disconnect()
                } catch {
                    // RCON didn't take -- fall back to signalling the pid,
                    // same as Rust's `sent_rcon = false` path.
                    self?.push(.system, "Stop requested — terminating the process…")
                    ServerSession.terminate(pid: pid)
                }
            }
        } else {
            push(.system, "Stop requested — terminating the process…")
            ServerSession.terminate(pid: pid)
        }

        // The adopted-monitor task (running since `adopt()`) is what
        // notices the exit and settles status — this watchdog only kills
        // and reports, exactly like the owned-child path.
        Task { [weak self] in
            for _ in 0..<(Self.gracefulStopSeconds * 2) {
                try? await Task.sleep(for: .milliseconds(500))
                if !ServerSession.serverAlive(pid: pid) { return }
            }
            guard let self else { return }
            self.push(.system, "Graceful stop timed out — killing process.")
            ServerSession.forceKill(pid: pid)
            for _ in 0..<20 where ServerSession.serverAlive(pid: pid) { try? await Task.sleep(for: .milliseconds(500)) }
            if ServerSession.serverAlive(pid: pid) {
                self.push(.system, "pid \(pid) is still around after a force-kill — it may need a manual kill.")
            }
        }
    }

    /// Force kill now. Mirrors `ProcessManager::kill`.
    @MainActor func forceKill() throws {
        if let pid = adoptedPid {
            snapshot.stopRequested = true
            push(.system, "Force killing process.")
            ServerSession.forceKill(pid: pid)
            return
        }
        guard let proc = process, proc.isRunning else {
            throw ProcessError.notRunning
        }
        snapshot.stopRequested = true
        push(.system, "Force killing process.")
        kill(proc.processIdentifier, SIGKILL)
    }

    @MainActor func writeStdin(_ line: String) throws {
        if adoptedPid != nil {
            throw ProcessError.adopted
        }
        guard let stdinPipe, isRunning else {
            throw ProcessError.notRunning
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        // Throwing API: with SIGPIPE ignored (AppDelegate), a server that
        // died between the isRunning check and here yields EPIPE as a Swift
        // error. The old `write(_:)` raised an uncatchable ObjC exception.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw ProcessError.notRunning
        }
    }

    /// Write `eula=true` so the next launch proceeds. Mirrors
    /// `ProcessManager::accept_eula`.
    @MainActor func acceptEULA(record: ServerRecord) throws {
        let path = URL(fileURLWithPath: record.path).appending(path: "eula.txt")
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let updated: String
        if existing.contains("eula=") {
            updated = existing
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("eula=") ? "eula=true" : String($0) }
                .joined(separator: "\n")
        } else {
            updated = existing.isEmpty ? "eula=true\n" : existing + "\neula=true\n"
        }
        try updated.write(to: path, atomically: true, encoding: .utf8)
        snapshot.needsEULA = false
    }

    // MARK: - Private

    /// Refreshes the folder-share lease every 30s while running — a no-op
    /// when this server isn't shared (`heartbeat` checks that itself).
    /// Release happens once, from `spawnMonitor`'s own exit detection, so
    /// this task only needs cancelling, not its own release call — same
    /// shape as `spawn_share_keeper`'s try_wait loop.
    @MainActor private func spawnShareHeartbeat(dir: URL) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                ShareLease.heartbeat(dir: dir, deviceID: ShareLease.thisDeviceID)
            }
        }
    }

    /// Reads a pipe line-by-line off the main actor, hopping back only to
    /// append. `AsyncStream` over `readabilityHandler` rather than a
    /// blocking read loop on a thread — the structured-concurrency
    /// equivalent of `process.rs`'s `spawn_reader` thread.
    @MainActor private func spawnReader(
        _ pipe: Pipe,
        stream: LogLine.Stream,
        serverType: ServerType,
        adapter: MinecraftAdapter
    ) -> Task<Void, Never> {
        let lines = Self.lineStream(from: pipe)
        return Task { [weak self] in
            for await text in lines {
                guard let self else { return }
                if text.contains("You need to agree to the EULA") {
                    self.snapshot.needsEULA = true
                }
                // promote Starting -> Running once the server reports ready
                if self.snapshot.status == .starting {
                    let running = serverType == .omnihost
                        ? OmniHostAdapter.parseStatus(text) == .running
                        : serverType.isGame
                        ? GameServers.parseStatus(serverType, output: text) == .running
                        : serverType.isBedrock
                        ? BedrockAdapter.parseStatus(text) == .running
                        : adapter.parseStatus(output: text) == .running
                    if running {
                        self.setStatus(.running)
                    }
                }
                if serverType == .omnihost {
                    // Short lines under the OMNIHost name; engine chatter is dropped.
                    if let shown = OmniHostLog.simplify(text) { self.push(stream, shown) }
                    continue
                }
                self.push(stream, text)
            }
        }
    }

    /// Splits raw pipe bytes into whole lines. Buffers a partial trailing
    /// line across reads — a naive per-chunk split would tear log lines in
    /// half at arbitrary byte boundaries, which is exactly the kind of bug
    /// that only shows up under real load.
    private nonisolated static func lineStream(from pipe: Pipe) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let tail = buffer.flush() { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) {
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
            }
        }
    }

    /// Polls for exit and settles the final status. Mirrors
    /// `process.rs`'s `spawn_monitor`, including the
    /// "requested-or-clean-exit means Stopped, otherwise Crashed" rule.
    @MainActor private func spawnMonitor(_ proc: Process, dir: URL) {
        Task { [weak self] in
            while proc.isRunning {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard let self else { return }
            let code = proc.terminationStatus
            self.snapshot.exitCode = code
            self.snapshot.pid = nil

            let clean = code == 0
            let final: ServerStatus = (self.snapshot.stopRequested || clean) ? .stopped : .crashed
            let how = proc.terminationReason == .uncaughtSignal
                ? "terminated by signal"
                : "exit code \(code)"
            self.push(.system, "Process ended (\(how)) — \(final == .crashed ? "crash" : "stopped")")
            self.setStatus(final)
            self.clearOnline()
            ShareLease.release(dir: dir, deviceID: ShareLease.thisDeviceID)
            self.readerTasks.forEach { $0.cancel() }
            self.readerTasks = []
            self.process = nil
            self.stdinPipe = nil
            ServerSession.clear(dir: dir)
        }
    }
}

/// Thread-safe accumulator for partial lines across pipe reads.
/// `readabilityHandler` fires on an arbitrary queue, so this needs its own
/// lock rather than relying on actor isolation — and must be explicitly
/// `nonisolated`, since this file's default isolation is MainActor and
/// inheriting that here would be a lie (the compiler correctly flagged it).
nonisolated final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var out: [String] = []
        while let idx = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<idx]
            pending.removeSubrange(pending.startIndex...idx)
            let text = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            out.append(text)
        }
        // A stream that never sends '\n' must not grow memory forever.
        if pending.count > Self.maxLine {
            out.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: false)
        }
        return out
    }

    static let maxLine = 64 * 1024

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text.isEmpty ? nil : text
    }
}

enum ProcessError: LocalizedError {
    case alreadyRunning
    case notRunning
    case folderMissing(String)
    case launchFailed(String)
    /// Tried to write to stdin on a re-adopted server, which has none.
    case adopted

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Server is already running."
        case .notRunning: "Server is not running."
        case .folderMissing(let p): "Server folder is missing: \(p)"
        case .launchFailed(let m): m
        case .adopted: "This server was reattached after a restart — send commands from the Players tab (RCON)."
        }
    }
}
