import Foundation

/// Session files — so a OMNIServers restart re-adopts the servers it
/// launched instead of mislabelling them "external" (which locked people
/// out of restarting them). Direct port of `session.rs`.
///
/// When a server starts, `<server>/.craftpanel-session.json` records the
/// child pid, the OMNIServers pid that spawned it, and the RCON endpoint
/// (so a fresh app instance can still stop it). The adopted-monitor
/// deletes the file when the process exits. On launch,
/// `ProcessManager.adoptAll` reads every file: if the pid is still a live
/// JVM it's re-adopted as Running (reattached); otherwise the stale file
/// is cleared.
nonisolated struct ServerSession: Codable, Sendable {
    /// The Minecraft / Bedrock child process.
    var pid: Int32
    /// The OMNIServers process that launched it (informational).
    var launcherPid: Int32
    var startedAt: Int64
    var rconPort: UInt16?
    var rconPassword: String?

    static let fileName = ".craftpanel-session.json"

    static func write(dir: URL, session: ServerSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: dir.appending(path: fileName))
    }

    static func read(dir: URL) -> ServerSession? {
        guard let data = try? Data(contentsOf: dir.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(ServerSession.self, from: data)
    }

    static func clear(dir: URL) {
        try? FileManager.default.removeItem(at: dir.appending(path: fileName))
    }

    /// Is `pid` a live process that looks like one of our servers?
    ///
    /// Native syscalls only (no `ps` subprocess — the old version blocked
    /// the main thread up to 2 s per call). Guards against pid reuse two
    /// ways: the command line must mention `java` or `bedrock_server`
    /// (the Rust source only knew "java", so Bedrock never re-adopted),
    /// and when the session's `startedAt` is known, the process's own start
    /// time must match it — so after a reboot, an unrelated JVM that
    /// happens to get the same pid is never adopted (or killed).
    static func serverAlive(pid: Int32, startedAt: Int64? = nil) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        let cmd = commandLine(pid).lowercased()
        guard cmd.contains("java") || cmd.contains("bedrock_server") || cmd.contains("/engines/pumpkin/") else { return false }
        if let startedAt, let procStart = startTime(pid) {
            // `startedAt` is stamped just after `Process.run()`.
            return abs(procStart - startedAt) <= 10
        }
        return true
    }

    /// Ask the process to stop (SIGTERM).
    static func terminate(pid: Int32) {
        guard pid > 0 else { return }
        // OMNIHost's engine saves on Ctrl-C (SIGINT); SIGTERM would just kill it.
        kill(pid, commandLine(pid).contains("/engines/pumpkin/") ? SIGINT : SIGTERM)
    }

    /// Force-kill the process (SIGKILL).
    static func forceKill(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    /// argv of `pid` joined by spaces, via `KERN_PROCARGS2`.
    static func commandLine(_ pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        let argc = buf.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        // Layout: argc, exec path, NULs, argv[0..argc-1] NUL-separated, env...
        var parts = buf[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !parts.isEmpty else { return "" }
        parts.removeFirst() // exec path
        return parts.prefix(argc).joined(separator: " ")
    }

    /// Process start time (unix seconds) via `proc_pidinfo`.
    static func startTime(_ pid: Int32) -> Int64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int64(info.pbi_start_tvsec)
    }
}

/// Best-effort RCON endpoint for a server folder, read at `start()` time
/// so a session file can record it for a later reattach-then-stop.
/// Thin wrapper over `Properties` (Batch B's line-preserving editor) —
/// kept as its own small entry point since `ServerRuntime` only ever
/// needs this one read, not the full editor.
nonisolated enum RconEndpointReader {
    static func read(dir: URL) -> (port: UInt16?, password: String?) {
        let props = Properties.load(dir: dir)
        guard props.getOr("enable-rcon", "false") == "true" else { return (nil, nil) }
        let port = props.get("rcon.port").flatMap { UInt16($0) }
        let password = props.get("rcon.password").flatMap { $0.isEmpty ? nil : $0 }
        return (port, password)
    }
}
