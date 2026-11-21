import XCTest
@testable import craftpanel_Swift

/// Batch A-2 tests: adopt/reattach on relaunch. Drives real processes and
/// real session files throughout, same discipline as `ProcessTests.swift`
/// — the stale-`adoptedPid` bug class this batch exists to prevent only
/// shows up against real process semantics.
@MainActor
final class AdoptTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var strays: [Process] = []

    override func tearDown() {
        for p in strays where p.isRunning { p.terminate() }
        strays = []
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-adopt-\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    private func fakeServer(_ dir: URL, script: String) -> ServerRecord {
        let scriptURL = dir.appending(path: "fake-java.sh")
        try! script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return ServerRecord(
            name: "test",
            path: dir.path,
            serverType: .vanilla,
            launchTarget: "server.jar",
            mcVersion: "1.21.1",
            javaPath: scriptURL.path,
            ramMB: 1024
        )
    }

    /// A long-lived process standing in for "some server OMNIServers
    /// reattached to at boot" — its command line must contain "java" for
    /// `ServerSession.serverAlive` to recognize it, same constraint the
    /// Rust fixture works around by naming its fake binary `fake-java`.
    /// Deliberately a *different* filename from `fakeServer`'s own
    /// `fake-java.sh` — reusing that name silently overwrote the real
    /// server script underneath a later `start()` in an earlier version
    /// of this test, which produced a spurious failure that looked like
    /// the actual bug this test exists to catch (a real lesson from
    /// getting this test wrong once, worth keeping as a comment).
    @discardableResult
    private func spawnStray(_ dir: URL) -> Process {
        let scriptURL = dir.appending(path: "stray-java.sh")
        try! "#!/bin/sh\nwhile true; do sleep 1; done\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let p = Process()
        p.executableURL = scriptURL
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try! p.run()
        strays.append(p)
        return p
    }

    private func wait(
        _ description: String,
        timeout: TimeInterval = 10,
        until condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        XCTFail("timed out waiting for: \(description)")
    }

    // MARK: - Session file round trip

    func testSessionFileRoundTripsAndClears() {
        let dir = makeTempDir("session")
        XCTAssertNil(ServerSession.read(dir: dir))

        let session = ServerSession(pid: 4321, launcherPid: 1, startedAt: 42, rconPort: 25575, rconPassword: "x")
        ServerSession.write(dir: dir, session: session)
        let read = ServerSession.read(dir: dir)
        XCTAssertEqual(read?.pid, 4321)
        XCTAssertEqual(read?.rconPort, 25575)

        ServerSession.clear(dir: dir)
        XCTAssertNil(ServerSession.read(dir: dir))
    }

    func testThisTestProcessIsNotAServer() {
        // our own pid is alive but its command line isn't a JVM
        XCTAssertFalse(ServerSession.serverAlive(pid: ProcessInfo.processInfo.processIdentifier))
        // a pid that's very unlikely to exist
        XCTAssertFalse(ServerSession.serverAlive(pid: 999_999_999))
    }

    func testRconEndpointReaderRequiresEnableRcon() {
        let dir = makeTempDir("rcon-props")
        try! """
        enable-rcon=true
        rcon.port=25575
        rcon.password=hunter2
        """.write(to: dir.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        let (port, password) = RconEndpointReader.read(dir: dir)
        XCTAssertEqual(port, 25575)
        XCTAssertEqual(password, "hunter2")

        let dirOff = makeTempDir("rcon-props-off")
        try! "enable-rcon=false\nrcon.port=25575\n".write(to: dirOff.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        let (portOff, passwordOff) = RconEndpointReader.read(dir: dirOff)
        XCTAssertNil(portOff)
        XCTAssertNil(passwordOff)
    }

    // MARK: - Adopt lifecycle

    func testAdoptReattachesToALiveSession() async throws {
        let dir = makeTempDir("adopt")
        var rec = fakeServer(dir, script: "#!/bin/sh\nwhile true; do sleep 1; done\n")
        rec.name = "adopted"
        let stray = spawnStray(dir)

        ServerSession.write(dir: dir, session: ServerSession(
            pid: stray.processIdentifier, launcherPid: 1, startedAt: Int64(Date().timeIntervalSince1970),
            rconPort: nil, rconPassword: nil
        ))

        let pm = ProcessManager()
        pm.adoptAll(records: [rec])

        let rt = pm.runtime(for: rec.id)
        XCTAssertEqual(rt.snapshot.status, .running)
        XCTAssertTrue(rt.snapshot.reattached)
        XCTAssertEqual(rt.snapshot.pid, stray.processIdentifier)
    }

    func testAdoptedMonitorNoticesExitAndClearsSession() async throws {
        let dir = makeTempDir("adopt-exit")
        var rec = fakeServer(dir, script: "#!/bin/sh\nwhile true; do sleep 1; done\n")
        rec.name = "adopted-exit"
        let stray = spawnStray(dir)

        ServerSession.write(dir: dir, session: ServerSession(
            pid: stray.processIdentifier, launcherPid: 1, startedAt: Int64(Date().timeIntervalSince1970),
            rconPort: nil, rconPassword: nil
        ))

        let pm = ProcessManager()
        pm.adoptAll(records: [rec])
        let rt = pm.runtime(for: rec.id)
        try await wait("adopted as running") { rt.snapshot.status == .running }

        ServerSession.forceKill(pid: stray.processIdentifier)
        try await wait("adopted exit noticed", timeout: 8) { rt.snapshot.status == .stopped }
        XCTAssertNil(ServerSession.read(dir: dir), "session file should be cleared once the adopted process exits")
    }

    func testDeadSessionIsClearedNotAdopted() {
        let dir = makeTempDir("adopt-dead")
        let rec = fakeServer(dir, script: "#!/bin/sh\nexit 0\n")
        ServerSession.write(dir: dir, session: ServerSession(
            pid: 999_999_999, launcherPid: 1, startedAt: 0, rconPort: nil, rconPassword: nil
        ))

        let pm = ProcessManager()
        pm.adoptAll(records: [rec])

        XCTAssertNil(ServerSession.read(dir: dir), "a session pointing at a dead pid must be cleared, not adopted")
        XCTAssertFalse(pm.isRunning(rec.id))
    }

    /// The regression test this batch exists for. Real bug on the Rust
    /// side: a server that had *ever* been reattached kept a stale
    /// `adoptedPid` around forever, so a later `stop()` — even on a
    /// genuinely fresh `start()` — kept targeting the old dead pid
    /// instead of the real child just spawned. The real process never
    /// got a correct kill signal and could hang "Stopping" indefinitely
    /// (this exact chain got a user's real server stuck for 38 minutes).
    /// Reproduces adopt -> stray dies -> fresh start -> stop, and asserts
    /// the second stop actually reaches the real child.
    func testStoppingAfterAFreshStartDoesNotTargetTheStaleAdoptedPid() async throws {
        let dir = makeTempDir("stale-adopt")
        var rec = fakeServer(dir, script: """
        #!/bin/sh
        echo '[12:00:01] [Server thread/INFO]: Done (1.0s)! For help, type "help"'
        while read -r line; do
          if [ "$line" = "stop" ]; then exit 0; fi
        done
        """)
        rec.name = "restart-me"
        let stray = spawnStray(dir)

        let pm = ProcessManager()
        let rt = pm.runtime(for: rec.id)
        rt.adopt(record: rec, session: ServerSession(
            pid: stray.processIdentifier, launcherPid: 1, startedAt: Int64(Date().timeIntervalSince1970),
            rconPort: nil, rconPassword: nil
        ))
        try await wait("adopted as running") { rt.snapshot.status == .running }

        // it exits (killed directly, standing in for "died on its own") —
        // the adopted-monitor notices and marks it Stopped, same as a
        // real crash/manual-kill would.
        ServerSession.forceKill(pid: stray.processIdentifier)
        try await wait("adopted exit noticed", timeout: 8) { rt.snapshot.status == .stopped }

        // now a genuinely fresh start — must fully take over as the real
        // owner of this server id, stale adoption metadata and all.
        try rt.start(record: rec)
        try await wait("running again") { rt.snapshot.status == .running }

        try rt.stop()
        try await wait("stopped again", timeout: 15) { rt.snapshot.status == .stopped }
        // exit_code 0 only happens if the real fake-java process received
        // its "stop" line over stdin and exited cleanly on its own terms
        // -- the pre-fix bug would leave this hanging in .stopping (or,
        // if it ever resolved, only via the 25s force-kill timeout, never
        // a clean exit) because the real child never got the command at
        // all -- stop() would have kept signalling the long-dead stray pid.
        XCTAssertEqual(rt.snapshot.exitCode, 0)
        XCTAssertFalse(
            rt.lines.contains { $0.text.contains("terminating the process") },
            "the second stop must never take the stale-adoption pid-signal path"
        )
    }
}
