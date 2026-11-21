import XCTest
@testable import craftpanel_Swift

/// Regression tests for the Phase 2/3 lifecycle fixes.
@MainActor
final class LifecycleHardeningTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func spawnStray() throws -> Process {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-life-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        let script = d.appending(path: "stray-java.sh")
        try "#!/bin/sh\nwhile true; do sleep 1; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = script
        try p.run()
        return p
    }

    func testCommandLineAndStartTimeAreReadNatively() throws {
        let p = try spawnStray()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(ServerSession.commandLine(p.processIdentifier).contains("stray-java.sh"))
        let start = try XCTUnwrap(ServerSession.startTime(p.processIdentifier))
        XCTAssertLessThan(abs(start - Int64(Date().timeIntervalSince1970)), 5)
    }

    /// pid reuse: a live java-looking process whose start time doesn't match
    /// the session file must not be adopted.
    func testServerAliveRejectsPidWithMismatchedStartTime() throws {
        let p = try spawnStray()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertTrue(ServerSession.serverAlive(pid: p.processIdentifier, startedAt: now))
        XCTAssertFalse(ServerSession.serverAlive(pid: p.processIdentifier, startedAt: now - 3600))
    }

    func testServerAliveFalseForDeadAndNonJavaPids() {
        XCTAssertFalse(ServerSession.serverAlive(pid: 999_999_999))
        XCTAssertFalse(ServerSession.serverAlive(pid: 0))
        XCTAssertFalse(ServerSession.serverAlive(pid: -1))
    }

    /// Writing to a server that has just died must throw, not crash the app
    /// with SIGPIPE / an ObjC exception.
    func testWriteStdinAfterChildExitThrowsInsteadOfCrashing() async throws {
        signal(SIGPIPE, SIG_IGN) // AppDelegate does this in the real app
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-life-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        let script = d.appending(path: "fake-java.sh")
        // Close stdin immediately, then linger so isRunning stays true briefly.
        try "#!/bin/sh\nexec 0<&-\nsleep 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let rec = ServerRecord(name: "t", path: d.path, serverType: .vanilla, launchTarget: "server.jar",
                               mcVersion: "1.21.1", javaPath: script.path, ramMB: 512)
        let rt = ServerRuntime(serverID: rec.id)
        try rt.start(record: rec)
        try await Task.sleep(for: .milliseconds(300))
        var threw = false
        for _ in 0..<50 { // pipe buffer is 64 KB; enough writes to hit EPIPE
            do { try rt.writeStdin(String(repeating: "x", count: 4096)) } catch { threw = true; break }
        }
        XCTAssertTrue(threw)
        try? rt.forceKill()
    }

    func testWithSavesPausedFlushesThenResumes() async throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-life-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        let log = d.appending(path: "cmds.log")
        let script = d.appending(path: "fake-java.sh")
        try """
        #!/bin/sh
        echo '[00:00:00] [Server thread/INFO]: Done (1.0s)! For help, type "help"'
        while read line; do
          echo "$line" >> "\(log.path)"
          case "$line" in
            "save-all flush") echo '[00:00:01] [Server thread/INFO]: Saved the game';;
            stop) exit 0;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let rec = ServerRecord(name: "t", path: d.path, serverType: .vanilla, launchTarget: "server.jar",
                               mcVersion: "1.21.1", javaPath: script.path, ramMB: 512)
        let pm = ProcessManager()
        try pm.start(rec)
        for _ in 0..<50 where pm.runtime(for: rec.id).snapshot.status != .running {
            try await Task.sleep(for: .milliseconds(100))
        }
        let didRun = try await pm.withSavesPaused(rec.id) { () async throws -> Bool in
            let seen = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return seen.contains("save-off") && seen.contains("save-all flush") && !seen.contains("save-on")
        }
        XCTAssertTrue(didRun, "body must run after the flush and before save-on")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("save-on"))
        try? pm.forceKill(rec.id)
    }
}

final class JavaAutoResolveTests: XCTestCase {
    func testGenericJavaResolvesToInstalledRuntime() throws {
        guard let managed = JavaInstaller.installedPath(feature: 25) else { throw XCTSkip("no managed Java 25 here") }
        XCTAssertEqual(JavaProbe.autoResolve(javaPath: "java", mcVersion: "26.2"), managed)
        XCTAssertNil(JavaProbe.autoResolve(javaPath: managed, mcVersion: "26.2"), "an explicit, existing path is left alone")
    }

    func testMissingExplicitPathIsReplaced() {
        let r = JavaProbe.autoResolve(javaPath: "/nope/bin/java", mcVersion: "26.2")
        if JavaInstaller.installedPath(feature: 25) != nil { XCTAssertNotNil(r) }
    }
}
