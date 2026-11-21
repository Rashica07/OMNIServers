import Foundation
import CryptoKit
import Darwin
import SwiftData

// Playit.gg integration. The official agent (github.com/playit-cloud/playit-agent, BSD-2-Clause) runs
// as a child process of OMNIServers: no service install, no terminal. It is started when the first server
// that wants a Playit address starts, and stopped when the last one stops (reference counted).
//
// Facts this file relies on were checked against agent v2.0.2 (release assets, `playitd --help`, the
// IPC source, and a real `playitd` answering over its socket). Not checked without an account: claiming,
// tunnel creation and the public address of a live tunnel — see docs/PLAYIT.md.

// MARK: - IPC protocol (JSON lines over a unix socket, ipc_version 3)

nonisolated struct PlayitTunnel: Equatable, Sendable {
    var id: String
    var displayAddress: String
    /// Where the agent forwards to, e.g. "127.0.0.1:25565".
    var destination: String
    var isDisabled: Bool
}

nonisolated enum PlayitLifecycle: Equatable, Sendable {
    case waitingForSecret
    case invalidSecret(String)
    case overLimit(String)
    case starting
    case running(agentID: String, tunnels: [PlayitTunnel], loginLink: String?)
    case stopping
    case error(String)
}

nonisolated enum PlayitMessage: Equatable, Sendable {
    case hello
    case lifecycle(PlayitLifecycle)
    case other
}

nonisolated enum PlayitProtocol {
    static let ipcVersion = 3

    /// One request as a newline-terminated JSON line. `type` is e.g. "subscribe", "get_state", "stop".
    static func request(_ type: String, id: Int) -> Data {
        let o: [String: Any] = ["ipc_version": ipcVersion, "request_id": id, "request": ["type": type]]
        return line(o)
    }

    static func setSecretRequest(_ secret: String, id: Int) -> Data {
        line(["ipc_version": ipcVersion, "request_id": id, "request": ["type": "set_secret", "secret": secret]])
    }

    private static func line(_ o: [String: Any]) -> Data {
        var d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        d.append(0x0A)
        return d
    }

    static func parse(_ text: String) -> PlayitMessage {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = root["message_kind"] as? String else { return .other }
        let payload = root["data"] as? [String: Any] ?? [:]
        switch kind {
        case "hello": return .hello
        case "response":
            let resp = payload["response"] as? [String: Any] ?? [:]
            let body = resp["data"] as? [String: Any] ?? [:]
            switch resp["type"] as? String {
            case "subscribe":
                if let snap = body["snapshot"] as? [String: Any], let l = snap["lifecycle"] as? [String: Any] {
                    return .lifecycle(lifecycle(l))
                }
            case "state": return .lifecycle(lifecycle(body))
            default: break
            }
        case "event":
            let ev = payload["event"] as? [String: Any] ?? [:]
            if ev["type"] as? String == "lifecycle", let d = ev["data"] as? [String: Any] { return .lifecycle(lifecycle(d)) }
        default: break
        }
        return .other
    }

    /// `{"state":"running","data":{…}}` or `{"state":"waiting_for_secret"}`.
    static func lifecycle(_ o: [String: Any]) -> PlayitLifecycle {
        let data = o["data"] as? [String: Any]
        let msg = (data?["message"] as? String) ?? "Unknown error"
        switch o["state"] as? String {
        case "waiting_for_secret": return .waitingForSecret
        case "has_invalid_secret": return .invalidSecret(msg)
        case "disabled_over_limit": return .overLimit(msg)
        case "starting": return .starting
        case "stopping": return .stopping
        case "error": return .error(msg)
        case "running":
            let tunnels = (data?["tunnels"] as? [[String: Any]] ?? []).map {
                PlayitTunnel(id: $0["id"] as? String ?? "", displayAddress: $0["display_address"] as? String ?? "",
                             destination: $0["destination"] as? String ?? "", isDisabled: $0["is_disabled"] as? Bool ?? false)
            }
            return .running(agentID: data?["agent_id"] as? String ?? "", tunnels: tunnels, loginLink: data?["login_link"] as? String)
        default: return .starting
        }
    }
}

// MARK: - Reference counting

/// Which servers currently need the agent. The agent runs exactly while this is non-empty.
nonisolated struct PlayitLeases: Equatable, Sendable {
    struct Lease: Equatable, Sendable { var port: Int; var bedrock: Bool; var name: String }
    private(set) var held: [UUID: Lease] = [:]

    var isEmpty: Bool { held.isEmpty }
    var count: Int { held.count }

    /// True when this took the count from 0 to 1 (the agent must start).
    mutating func acquire(_ id: UUID, _ lease: Lease) -> Bool {
        let wasEmpty = held.isEmpty
        held[id] = lease
        return wasEmpty
    }

    /// True when this took the count from 1 to 0 (the agent must stop). Releasing something not held is a no-op.
    mutating func release(_ id: UUID) -> Bool {
        guard held.removeValue(forKey: id) != nil else { return false }
        return held.isEmpty
    }
}

// MARK: - Secrets never reach logs

nonisolated enum PlayitRedactor {
    private static let patterns: [NSRegularExpression] = [
        #"(?i)(agent-key\s+)\S+"#, #"(?i)(--secret[= ]\s*)\S+"#, #"(?i)(secret(_key)?\s*[=:]\s*"?)[A-Za-z0-9._\-]{8,}"#,
        #"(?i)(bearer\s+)\S+"#, #"\b[0-9a-f]{40,}\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ s: String) -> String {
        var out = s
        for re in patterns {
            let range = NSRange(out.startIndex..., in: out)
            let hasGroup = re.numberOfCaptureGroups > 0
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: hasGroup ? "$1[hidden]" : "[hidden]")
        }
        return out
    }
}

// MARK: - Playit API (tunnel creation)

nonisolated enum PlayitAPI {
    static let base = "https://api.playit.gg"

    /// Body for POST /v1/tunnels/create — a Minecraft tunnel whose origin is this agent at 127.0.0.1:port.
    static func createTunnelBody(agentID: String, bedrock: Bool, port: Int, name: String) -> [String: Any] {
        [
            "ports": ["type": "tunnel-type", "details": bedrock ? "minecraft-bedrock" : "minecraft-java"],
            "origin": ["type": "agent", "data": [
                "agent_id": agentID,
                "config": ["fields": [["name": "local_ip", "value": "127.0.0.1"], ["name": "local_port", "value": String(port)]]],
            ]],
            "enabled": true,
            "alloc": NSNull(),
            "name": name,
            "firewall_id": NSNull(),
        ]
    }

    enum APIError: LocalizedError {
        case rejected(String), network(String)
        var errorDescription: String? {
            switch self { case .rejected(let m): "Playit said no: \(m)"; case .network(let m): "Couldn't reach Playit: \(m)" }
        }
    }

    /// Creates the tunnel. The secret goes in the Authorization header only and is never logged.
    static func createTunnel(secret: String, agentID: String, bedrock: Bool, port: Int, name: String) async throws {
        var req = URLRequest(url: URL(string: base + "/v1/tunnels/create")!)
        req.httpMethod = "POST"
        req.setValue("Agent-Key \(secret.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: createTunnelBody(agentID: agentID, bedrock: bedrock, port: port, name: name))
        req.timeoutInterval = 20
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if obj["status"] as? String == "success" { return }
            throw APIError.rejected(PlayitRedactor.redact(String(decoding: data.prefix(300), as: UTF8.self)))
        } catch let e as APIError { throw e } catch { throw APIError.network(error.localizedDescription) }
    }
}

// MARK: - Binary: pinned version, checksum verified, never run unverified

nonisolated enum PlayitBinary {
    static let version = "2.0.2"
    /// SHA-256 of `playit-macos-universal.tar.gz` for v2.0.2 (from the GitHub release page; also checked by hand).
    static let sha256 = "d3da262f8c58bfc13797a1bbf2e3fcc6d487e4e6832f54b35c00daeb59e1cce2"
    static let url = URL(string: "https://github.com/playit-cloud/playit-agent/releases/download/v\(version)/playit-macos-universal.tar.gz")!

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CraftPanel/playit/\(version)", isDirectory: true)
    }
    static var daemon: URL { dir.appendingPathComponent("playitd") }
    static var cli: URL { dir.appendingPathComponent("playit") }
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: daemon.path) && FileManager.default.isExecutableFile(atPath: cli.path)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ data: Data, expected: String = sha256) -> Bool { sha256Hex(data) == expected }

    /// Downloads, verifies and unpacks. A download that doesn't match the pinned hash is deleted unrun.
    static func install() async throws {
        if isInstalled { return }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        guard verify(data) else {
            throw ProvisionError.message("The Playit download didn't match its published checksum, so OMNIServers deleted it rather than run it.")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try await Subprocess.runAsync("/usr/bin/tar", ["-xzf", tmp.path, "-C", dir.path, "--strip-components=1"], timeout: 60)
        guard r.status == 0, isInstalled else { throw ProvisionError.message("Couldn't unpack the Playit agent.") }
    }
}

// MARK: - Claim (account link) — drives `playit claim …`, no terminal for the user

nonisolated enum PlayitClaim {
    struct Started: Sendable { var code: String; var url: URL }

    static func begin(name: String = "OMNIServers") async throws -> Started {
        let g = try await Subprocess.runAsync(PlayitBinary.cli.path, ["claim", "generate"], timeout: 15)
        let code = g.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard g.status == 0, !code.isEmpty else { throw ProvisionError.message("Couldn't start the Playit sign-in.") }
        let u = try await Subprocess.runAsync(PlayitBinary.cli.path, ["claim", "url", code, "--name", name], timeout: 15)
        let text = u.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https" else { throw ProvisionError.message("Playit didn't return a sign-in link.") }
        return Started(code: code, url: url)
    }

    /// Waits (up to `seconds`) for the user to approve in the browser, then returns the agent secret.
    static func exchange(code: String, seconds: Int = 300) async throws -> String {
        let r = try await Subprocess.runAsync(PlayitBinary.cli.path, ["claim", "exchange", code, "--wait", String(seconds)], timeout: TimeInterval(seconds + 10))
        let secret = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !secret.isEmpty else { throw ProvisionError.message("The Playit sign-in wasn't approved in time. Try again.") }
        return secret
    }

    static let keychainAccount = "playit.secret"
    static var hasSecret: Bool { Keychain.get(keychainAccount) != nil }
}

// MARK: - The daemon process

/// What the manager needs from the running agent. A fake stands in for it in tests.
protocol PlayitDaemon: AnyObject, Sendable {
    /// Runs until the daemon exits (or its connection drops). Lifecycle updates arrive via `onLifecycle`.
    func run(onLifecycle: @escaping @Sendable (PlayitLifecycle) -> Void) async
    /// Hands the agent its secret over IPC (it persists it itself).
    func setSecret(_ secret: String) async
    /// SIGTERM, then SIGKILL after `grace`. Returns when the process is gone.
    func terminate(grace: Duration) async
}

final class PlayitProcessDaemon: PlayitDaemon, @unchecked Sendable {
    private let process = Process()
    private let socketPath: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var nextID = 100

    static var runDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CraftPanel/playit/run", isDirectory: true)
    }
    /// unix socket paths max out near 104 bytes on macOS, so the socket lives in a short private folder.
    static func shortSocketDir() -> String { "/tmp/omni-\(getuid())" }

    init() throws {
        let sockDir = Self.shortSocketDir()
        try FileManager.default.createDirectory(atPath: sockDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: Self.runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socketPath = sockDir + "/playit.sock"
        try? FileManager.default.removeItem(atPath: socketPath)
        process.executableURL = PlayitBinary.daemon
        process.arguments = ["--secret-path", Self.runDir.appendingPathComponent("secret.toml").path,
                             "--socket-path", socketPath,
                             "--log-path", Self.runDir.appendingPathComponent("playitd.log").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
    }

    func run(onLifecycle: @escaping @Sendable (PlayitLifecycle) -> Void) async {
        do { try process.run() } catch { onLifecycle(.error("Couldn't start the Playit agent: \(error.localizedDescription)")); return }
        let exited = Task.detached { [process] in process.waitUntilExit() }
        // Connect once the socket exists (the agent creates it a moment after launch).
        var connected = false
        for _ in 0..<50 where process.isRunning {
            if connect() { connected = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if connected {
            send(PlayitProtocol.request("subscribe", id: 1))
            let reader = Task.detached { [weak self] in
                guard let self, let h = self.handle() else { return }
                do { for try await line in h.bytes.lines { if case .lifecycle(let l) = PlayitProtocol.parse(line) { onLifecycle(l) } } } catch {}
            }
            _ = await exited.value
            reader.cancel()
        } else {
            _ = await exited.value
        }
        closeSocket()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func setSecret(_ secret: String) async {
        lock.lock(); nextID += 1; let id = nextID; lock.unlock()
        send(PlayitProtocol.setSecretRequest(secret, id: id))
    }

    func terminate(grace: Duration) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now + grace
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: socket plumbing
    private func connect() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = UInt8(bitPattern: b) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(s); return false }
        lock.lock(); fd = s; lock.unlock()
        return true
    }
    private func handle() -> FileHandle? {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: false) : nil
    }
    private func send(_ d: Data) { handle()?.write(d) }
    private func closeSocket() { lock.lock(); if fd >= 0 { close(fd); fd = -1 }; lock.unlock() }
}

// MARK: - Lifecycle manager

@MainActor
@Observable
final class PlayitAgent {
    static let shared = PlayitAgent()

    enum Phase: Equatable {
        case off, installing, starting, needsClaim, connecting, connected, reconnecting, error(String)
        var label: String {
            switch self {
            case .off: "Off"
            case .installing: "Setting up Playit…"
            case .starting: "Starting Playit…"
            case .needsClaim: "Waiting for you to sign in to Playit"
            case .connecting: "Opening your tunnel…"
            case .connected: "Connected"
            case .reconnecting: "Playit dropped, reconnecting…"
            case .error(let m): m
            }
        }
    }

    private(set) var phase: Phase = .off
    private(set) var tunnels: [PlayitTunnel] = []
    private(set) var loginLink: String?
    /// How many times the agent was relaunched after dying while a server still needed it (for diagnostics).
    private(set) var restarts = 0

    private var leases = PlayitLeases()
    private var daemon: PlayitDaemon?
    private var supervisor: Task<Void, Never>?
    private var requestedTunnels: Set<String> = []

    // Injection points (real implementations by default; tests replace them).
    var install: () async throws -> Void = { try await PlayitBinary.install() }
    var makeDaemon: () throws -> PlayitDaemon = { try PlayitProcessDaemon() }
    var secret: () -> String? = { Keychain.get(PlayitClaim.keychainAccount) }
    var createTunnel: (_ secret: String, _ agentID: String, _ bedrock: Bool, _ port: Int, _ name: String) async throws -> Void =
        { try await PlayitAPI.createTunnel(secret: $0, agentID: $1, bedrock: $2, port: $3, name: $4) }
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    var isRunning: Bool { supervisor != nil }
    var heldCount: Int { leases.count }

    /// The public address for a server's local port, once its tunnel is up.
    func address(forPort port: Int) -> String? {
        tunnels.first { $0.destination.hasSuffix(":\(port)") && !$0.isDisabled }?.displayAddress
    }

    /// A server that wants a Playit address is starting. Starts the agent if this is the first one.
    func acquire(_ serverID: UUID, port: Int, bedrock: Bool, name: String) {
        let mustStart = leases.acquire(serverID, .init(port: port, bedrock: bedrock, name: name))
        if mustStart { startSupervisor() }
        else if case .connected = phase, let d = daemonSnapshot { ensureTunnels(for: d) }
    }

    /// The server stopped (or crashed). Stops the agent if it was the last one.
    func release(_ serverID: UUID) {
        if leases.release(serverID) { stopSupervisor() }
    }

    /// App is quitting: nothing may outlive it.
    func shutdown() async {
        leases = PlayitLeases()
        await stopAndWait()
    }

    // MARK: internals

    private var daemonSnapshot: (agentID: String, tunnels: [PlayitTunnel])?

    private func startSupervisor() {
        guard supervisor == nil else { return }
        phase = .installing
        supervisor = Task { [weak self] in
            guard let self else { return }
            var backoff = Duration.seconds(1)
            while !Task.isCancelled, !self.leases.isEmpty {
                do { try await self.install() } catch {
                    self.phase = .error("Couldn't set up Playit: \(error.localizedDescription)"); break
                }
                self.phase = .starting
                let d: PlayitDaemon
                do { d = try self.makeDaemon() } catch { self.phase = .error("Couldn't start Playit: \(error.localizedDescription)"); break }
                self.daemon = d
                let started = ContinuousClock.now
                await d.run { [weak self] l in Task { @MainActor in self?.handle(l, daemon: d) } }
                self.daemon = nil
                self.daemonSnapshot = nil
                self.tunnels = []
                if Task.isCancelled || self.leases.isEmpty { break }
                // Died while a server still needs it: relaunch with backoff (reset after a healthy run).
                if ContinuousClock.now - started > .seconds(60) { backoff = .seconds(1) }
                self.restarts += 1
                self.phase = .reconnecting
                await self.sleep(backoff)
                backoff = min(backoff * 2, .seconds(30))
            }
            self.supervisor = nil
            if case .error = self.phase {} else { self.phase = .off }
        }
    }

    private func stopSupervisor() {
        Task { await stopAndWait() }
    }

    private func stopAndWait() async {
        let task = supervisor
        task?.cancel()
        await daemon?.terminate(grace: .seconds(5))
        await task?.value
        supervisor = nil; daemon = nil; daemonSnapshot = nil
        tunnels = []; loginLink = nil; requestedTunnels = []
        phase = .off
    }

    private func handle(_ l: PlayitLifecycle, daemon d: PlayitDaemon) {
        switch l {
        case .waitingForSecret:
            if let s = secret() { phase = .connecting; Task { await d.setSecret(s) } } else { phase = .needsClaim }
        case .invalidSecret: phase = .needsClaim
        case .overLimit(let m): phase = .error(m)
        case .starting: phase = .starting
        case .stopping: break
        case .error(let m): phase = .error(m)
        case .running(let agentID, let ts, let link):
            tunnels = ts; loginLink = link
            daemonSnapshot = (agentID, ts)
            ensureTunnels(for: daemonSnapshot!)
            phase = leases.held.values.allSatisfy({ lease in ts.contains { $0.destination.hasSuffix(":\(lease.port)") } }) ? .connected : .connecting
        }
    }

    /// Creates a tunnel for every held server that doesn't have one yet (once per server per agent run).
    private func ensureTunnels(for snap: (agentID: String, tunnels: [PlayitTunnel])) {
        guard let s = secret() else { return }
        for lease in leases.held.values {
            let key = "\(lease.port)-\(lease.bedrock)"
            if snap.tunnels.contains(where: { $0.destination.hasSuffix(":\(lease.port)") }) || requestedTunnels.contains(key) { continue }
            requestedTunnels.insert(key)
            Task { [weak self] in
                do { try await self?.createTunnel(s, snap.agentID, lease.bedrock, lease.port, "OMNI \(lease.name)") }
                catch { self?.requestedTunnels.remove(key); self?.phase = .error(error.localizedDescription) }
            }
        }
    }
}

// MARK: - Wiring: servers -> agent

/// Playit is optional and per server. Off unless the user turns it on for that server (Network tab).
nonisolated enum PlayitSettings {
    static func isEnabled(_ id: UUID) -> Bool { UserDefaults.standard.bool(forKey: "cp.playit.\(id.uuidString)") }
    static func setEnabled(_ id: UUID, _ on: Bool) { UserDefaults.standard.set(on, forKey: "cp.playit.\(id.uuidString)") }
}

/// Turns server status changes into agent leases. The agent starts when a server that opted in begins
/// starting, and stops when the last such server stops or crashes.
@MainActor
final class PlayitCoordinator {
    static let shared = PlayitCoordinator()
    private var container: ModelContainer?
    func configure(container: ModelContainer) { self.container = container }

    func statusChanged(serverID: UUID, status: ServerStatus) {
        switch status {
        case .starting, .running:
            guard PlayitSettings.isEnabled(serverID), let c = container else { return }
            var d = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == serverID })
            d.fetchLimit = 1
            guard let rec = try? c.mainContext.fetch(d).first else { return }
            let port = Int(NetworkInfo.port(serverDir: URL(fileURLWithPath: rec.path)))
            PlayitAgent.shared.acquire(serverID, port: port, bedrock: rec.serverType.isBedrock, name: rec.name)
        case .stopped, .crashed:
            PlayitAgent.shared.release(serverID)
        default: break
        }
    }
}
