import XCTest
@testable import craftpanel_Swift

final class FakePlayitDaemon: PlayitDaemon, @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    private var finished = false
    private(set) var terminated = false
    private(set) var secretsReceived: [String] = []
    private var sink: (@Sendable (PlayitLifecycle) -> Void)?

    func run(onLifecycle: @escaping @Sendable (PlayitLifecycle) -> Void) async {
        lock.lock(); sink = onLifecycle; lock.unlock()
        await withCheckedContinuation { c in
            lock.lock()
            if finished { lock.unlock(); c.resume() } else { cont = c; lock.unlock() }
        }
    }
    func setSecret(_ secret: String) async { lock.lock(); secretsReceived.append(secret); lock.unlock() }
    func terminate(grace: Duration) async { lock.lock(); terminated = true; lock.unlock(); exit() }
    func emit(_ l: PlayitLifecycle) { lock.lock(); let s = sink; lock.unlock(); s?(l) }
    /// The process dies on its own.
    func exit() {
        lock.lock(); finished = true; let c = cont; cont = nil; lock.unlock()
        c?.resume()
    }
}

@MainActor
final class PlayitAgentTests: XCTestCase {
    private func makeAgent(secret: String? = nil, daemons: @escaping () -> FakePlayitDaemon) -> PlayitAgent {
        let a = PlayitAgent()
        a.install = {}
        a.makeDaemon = { daemons() }
        a.secret = { secret }
        a.sleep = { _ in await Task.yield() }
        a.createTunnel = { _, _, _, _, _ in }
        return a
    }

    private func until(_ timeout: Double = 3, _ cond: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: lifecycle

    func testStartsOnFirstServerAndStopsOnLast() async {
        var made: [FakePlayitDaemon] = []
        let a = makeAgent { let d = FakePlayitDaemon(); made.append(d); return d }
        XCTAssertEqual(a.phase, .off, "OFF until a server needs it")
        XCTAssertFalse(a.isRunning)

        let s1 = UUID(), s2 = UUID()
        a.acquire(s1, port: 25565, bedrock: false, name: "One")
        await until { made.count == 1 }
        XCTAssertEqual(made.count, 1)
        a.acquire(s2, port: 25566, bedrock: false, name: "Two")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(made.count, 1, "second server shares the agent")

        a.release(s1)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(made[0].terminated, "agent stays while another server needs it")
        XCTAssertEqual(a.heldCount, 1)

        a.release(s2)
        await until { made[0].terminated }
        XCTAssertTrue(made[0].terminated, "last server stopped -> agent stopped")
        await until { !a.isRunning }
        XCTAssertEqual(a.phase, .off)
    }

    func testReleaseOfUnknownServerDoesNothing() async {
        var made = 0
        let a = makeAgent { made += 1; return FakePlayitDaemon() }
        a.release(UUID())
        XCTAssertEqual(made, 0)
        XCTAssertFalse(a.isRunning)
    }

    func testRecoversWhenAgentDiesWhileServerRuns() async {
        var made: [FakePlayitDaemon] = []
        let a = makeAgent { let d = FakePlayitDaemon(); made.append(d); return d }
        a.acquire(UUID(), port: 25565, bedrock: false, name: "One")
        await until { made.count == 1 }
        made[0].exit() // crash
        await until { made.count == 2 }
        XCTAssertEqual(made.count, 2, "relaunched while the server still needs it")
        XCTAssertEqual(a.restarts, 1)
    }

    func testNoRestartWhenNothingNeedsTheAgent() async {
        var made: [FakePlayitDaemon] = []
        let a = makeAgent { let d = FakePlayitDaemon(); made.append(d); return d }
        let s = UUID()
        a.acquire(s, port: 25565, bedrock: false, name: "One")
        await until { made.count == 1 }
        a.release(s)
        await until { !a.isRunning }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(a.restarts, 0)
    }

    func testShutdownLeavesNothingRunning() async {
        var made: [FakePlayitDaemon] = []
        let a = makeAgent { let d = FakePlayitDaemon(); made.append(d); return d }
        a.acquire(UUID(), port: 25565, bedrock: false, name: "One")
        a.acquire(UUID(), port: 25566, bedrock: false, name: "Two")
        await until { made.count == 1 }
        await a.shutdown()
        XCTAssertTrue(made[0].terminated)
        XCTAssertFalse(a.isRunning)
        XCTAssertEqual(a.heldCount, 0)
    }

    // MARK: sign-in and tunnels

    func testAsksToSignInWhenThereIsNoSecret() async {
        var d: FakePlayitDaemon?
        let a = makeAgent(secret: nil) { let x = FakePlayitDaemon(); d = x; return x }
        a.acquire(UUID(), port: 25565, bedrock: false, name: "One")
        await until { d != nil }
        try? await Task.sleep(for: .milliseconds(20))
        d?.emit(.waitingForSecret)
        await until { a.phase == .needsClaim }
        XCTAssertEqual(a.phase, .needsClaim)
    }

    func testHandsStoredSecretToAgent() async {
        var d: FakePlayitDaemon?
        let a = makeAgent(secret: "stored-secret-123") { let x = FakePlayitDaemon(); d = x; return x }
        a.acquire(UUID(), port: 25565, bedrock: false, name: "One")
        await until { d != nil }
        try? await Task.sleep(for: .milliseconds(20))
        d?.emit(.waitingForSecret)
        await until { d?.secretsReceived.isEmpty == false }
        XCTAssertEqual(d?.secretsReceived, ["stored-secret-123"])
    }

    func testCreatesMissingTunnelThenShowsAddress() async {
        var d: FakePlayitDaemon?
        var created: [(Bool, Int, String)] = []
        let a = makeAgent(secret: "s3cret-value") { let x = FakePlayitDaemon(); d = x; return x }
        a.createTunnel = { _, agent, bedrock, port, name in
            XCTAssertEqual(agent, "agent-1")
            created.append((bedrock, port, name))
        }
        a.acquire(UUID(), port: 25565, bedrock: false, name: "Survival")
        await until { d != nil }
        try? await Task.sleep(for: .milliseconds(20))
        d?.emit(.running(agentID: "agent-1", tunnels: [], loginLink: nil))
        await until { !created.isEmpty }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.1, 25565)
        XCTAssertEqual(created.first?.2, "OMNI Survival")
        XCTAssertNil(a.address(forPort: 25565))

        d?.emit(.running(agentID: "agent-1", tunnels: [PlayitTunnel(id: "t1", displayAddress: "abc.joinmc.link", destination: "127.0.0.1:25565", isDisabled: false)], loginLink: nil))
        await until { a.phase == .connected }
        XCTAssertEqual(a.address(forPort: 25565), "abc.joinmc.link")
        XCTAssertEqual(created.count, 1, "no duplicate tunnel")
    }

    // MARK: pure pieces

    func testLeaseCounting() {
        var l = PlayitLeases()
        let a = UUID(), b = UUID()
        XCTAssertTrue(l.acquire(a, .init(port: 1, bedrock: false, name: "a")))
        XCTAssertFalse(l.acquire(b, .init(port: 2, bedrock: false, name: "b")))
        XCTAssertFalse(l.acquire(a, .init(port: 1, bedrock: false, name: "a")), "re-acquire is not a new start")
        XCTAssertFalse(l.release(a))
        XCTAssertFalse(l.release(a), "double release is harmless")
        XCTAssertTrue(l.release(b))
    }

    func testParsesRealAgentMessages() {
        // Captured from a real playitd 2.0.2.
        XCTAssertEqual(PlayitProtocol.parse(#"{"message_kind":"hello","data":{"protocol":{"ipc_version":3,"capabilities":[]}}}"#), .hello)
        XCTAssertEqual(PlayitProtocol.parse(#"{"message_kind":"response","data":{"ipc_version":3,"request_id":2,"response":{"type":"state","data":{"state":"waiting_for_secret"}}}}"#),
                       .lifecycle(.waitingForSecret))
        let sub = #"{"message_kind":"response","data":{"ipc_version":3,"request_id":9,"response":{"type":"subscribe","data":{"protocol":{},"snapshot":{"status":{},"lifecycle":{"state":"waiting_for_secret"},"stats":{}}}}}}"#
        XCTAssertEqual(PlayitProtocol.parse(sub), .lifecycle(.waitingForSecret))
    }

    func testParsesRunningWithTunnels() {
        let run = #"{"message_kind":"event","data":{"ipc_version":3,"event":{"type":"lifecycle","data":{"state":"running","data":{"version":"2.0.2","tunnels":[{"id":"t1","display_address":"x.joinmc.link","destination":"127.0.0.1:25565","is_disabled":false}],"pending_tunnels":[],"notices":[],"account_status":"guest","agent_id":"ag","login_link":null,"start_time":1}}}}}"#
        XCTAssertEqual(PlayitProtocol.parse(run),
                       .lifecycle(.running(agentID: "ag", tunnels: [PlayitTunnel(id: "t1", displayAddress: "x.joinmc.link", destination: "127.0.0.1:25565", isDisabled: false)], loginLink: nil)))
        XCTAssertEqual(PlayitProtocol.parse("not json"), .other)
    }

    func testRequestIsOneJSONLine() throws {
        let d = PlayitProtocol.request("subscribe", id: 7)
        XCTAssertEqual(d.last, 0x0A)
        let o = try JSONSerialization.jsonObject(with: d.dropLast()) as? [String: Any]
        XCTAssertEqual(o?["ipc_version"] as? Int, 3)
        XCTAssertEqual(o?["request_id"] as? Int, 7)
        XCTAssertEqual((o?["request"] as? [String: Any])?["type"] as? String, "subscribe")
    }

    func testRedactorHidesSecrets() {
        let key = "abcdef0123456789abcdef0123456789abcdef01"
        for line in ["Authorization: Agent-Key \(key)", "playitd --secret \(key)", "secret_key = \"\(key)\"", "token \(key) ok"] {
            let out = PlayitRedactor.redact(line)
            XCTAssertFalse(out.contains(key), line)
        }
        XCTAssertEqual(PlayitRedactor.redact("tunnel ready on x.joinmc.link"), "tunnel ready on x.joinmc.link")
    }

    func testBinaryChecksum() {
        let data = Data("hello".utf8)
        XCTAssertEqual(PlayitBinary.sha256Hex(data), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertTrue(PlayitBinary.verify(data, expected: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
        XCTAssertFalse(PlayitBinary.verify(Data("tampered".utf8)), "wrong bytes never match the pinned hash")
    }

    func testTunnelRequestBody() throws {
        let java = PlayitAPI.createTunnelBody(agentID: "ag", bedrock: false, port: 25565, name: "OMNI A")
        let bedrock = PlayitAPI.createTunnelBody(agentID: "ag", bedrock: true, port: 19132, name: "OMNI B")
        XCTAssertEqual(((java["ports"] as? [String: Any])?["details"]) as? String, "minecraft-java")
        XCTAssertEqual(((bedrock["ports"] as? [String: Any])?["details"]) as? String, "minecraft-bedrock")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: java), as: UTF8.self)
        XCTAssertTrue(json.contains("\"local_port\"") && json.contains("25565") && json.contains("127.0.0.1"))
        XCTAssertFalse(json.contains("Agent-Key"), "the secret is a header, never in the body")
    }

    func testSocketDirIsShortEnough() {
        // macOS unix socket paths top out near 104 bytes.
        XCTAssertLessThan((PlayitProcessDaemon.shortSocketDir() + "/playit.sock").utf8.count, 100)
    }
}

/// Real agent, real process. Opt-in (downloads the checksum-pinned 10.8 MB agent on first run):
/// `PLAYIT_LIVE=1 xcodebuild test … -only-testing:craftpanel-SwiftTests/PlayitLiveTests`
@MainActor
final class PlayitLiveTests: XCTestCase {
    private func daemonPIDs() -> [String] {
        let r = try? Subprocess.run("/usr/bin/pgrep", ["-f", "playit/\(PlayitBinary.version)/playitd"], timeout: 5)
        return (r?.stdoutString ?? "").split(separator: "\n").map(String.init)
    }

    func testRealAgentStartsWaitsForSignInAndStopsCleanly() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLAYIT_LIVE"] == "1", "set PLAYIT_LIVE=1 to run")
        let a = PlayitAgent()
        a.secret = { nil } // no account: the agent must report it needs a sign-in
        XCTAssertTrue(daemonPIDs().isEmpty, "OFF before any server")

        let server = UUID()
        a.acquire(server, port: 25565, bedrock: false, name: "Live")
        let end = Date().addingTimeInterval(90)
        while a.phase != .needsClaim, Date() < end { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertEqual(a.phase, .needsClaim)
        XCTAssertEqual(daemonPIDs().count, 1, "exactly one agent process while a server needs it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: PlayitProcessDaemon.shortSocketDir() + "/playit.sock"))

        a.release(server)
        let end2 = Date().addingTimeInterval(15)
        while (a.isRunning || !daemonPIDs().isEmpty), Date() < end2 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(daemonPIDs().isEmpty, "no orphaned agent after the last server stops")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PlayitProcessDaemon.shortSocketDir() + "/playit.sock"), "socket cleaned up")
        XCTAssertEqual(a.phase, .off)
    }
}
