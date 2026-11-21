import XCTest
@testable import craftpanel_Swift

/// Batch A tests. The lifecycle ones drive a *real* child process (a shell
/// script standing in for a Minecraft server) rather than a mock — the
/// stuck-in-"Stopping" class of bug the Rust side hit only shows up
/// against real process semantics, so mocking it away would defeat the
/// point of testing it at all.
@MainActor
final class ServerRuntimeTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-proc-\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    /// Writes an executable script and returns a ServerRecord pointing at
    /// it via `javaPath`, so `startCommand`'s real argv shape still runs.
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

    // MARK: - Ring buffer

    func testConsoleRingBufferIsBounded() {
        let rt = ServerRuntime(serverID: UUID())
        for i in 0..<(ServerRuntime.ringCapacity + 250) {
            rt.push(.stdout, "line \(i)")
        }
        XCTAssertEqual(rt.lines.count, ServerRuntime.ringCapacity)
        // oldest dropped, newest kept
        XCTAssertEqual(rt.lines.last?.text, "line \(ServerRuntime.ringCapacity + 249)")
        XCTAssertFalse(rt.lines.contains { $0.text == "line 0" })
    }

    // MARK: - Full lifecycle against a real process

    func testStartReachesRunningOnReadyLine() async throws {
        let dir = makeTempDir("start")
        // Emits the real vanilla "Done (…)! For help…" ready line that
        // MinecraftAdapter.parseStatus keys off, then idles.
        let rec = fakeServer(dir, script: """
        #!/bin/sh
        echo '[12:00:00] [Server thread/INFO]: Starting minecraft server version 1.21.1'
        echo '[12:00:01] [Server thread/INFO]: Done (1.234s)! For help, type "help"'
        while read -r line; do
          if [ "$line" = "stop" ]; then
            echo '[12:00:09] [Server thread/INFO]: Stopping the server'
            exit 0
          fi
        done
        """)

        let rt = ServerRuntime(serverID: rec.id)
        try rt.start(record: rec)
        XCTAssertEqual(rt.snapshot.status, .starting)

        try await wait("status == .running") { rt.snapshot.status == .running }
        XCTAssertNotNil(rt.snapshot.pid)
        XCTAssertTrue(rt.lines.contains { $0.text.contains("Done (") })
    }

    func testGracefulStopExitsCleanlyAndReportsStopped() async throws {
        let dir = makeTempDir("stop")
        let rec = fakeServer(dir, script: """
        #!/bin/sh
        echo '[12:00:01] [Server thread/INFO]: Done (1.0s)! For help, type "help"'
        while read -r line; do
          if [ "$line" = "stop" ]; then exit 0; fi
        done
        """)

        let rt = ServerRuntime(serverID: rec.id)
        try rt.start(record: rec)
        try await wait("running") { rt.snapshot.status == .running }

        try rt.stop()
        XCTAssertTrue(rt.snapshot.stopRequested)

        try await wait("stopped") { rt.snapshot.status == .stopped }
        XCTAssertEqual(rt.snapshot.exitCode, 0)
        XCTAssertNil(rt.snapshot.pid)
    }

    /// The regression test the plan calls for: a process that ignores
    /// `stop` on stdin must still be force-killed by the watchdog rather
    /// than leaving status pinned at "Stopping" forever — the exact
    /// user-visible symptom of the Rust-side bug.
    func testStopWatchdogForceKillsAServerThatIgnoresStop() async throws {
        let dir = makeTempDir("wedged")
        // Traps SIGTERM and ignores stdin entirely — only SIGKILL ends it.
        let rec = fakeServer(dir, script: """
        #!/bin/sh
        trap '' TERM
        echo '[12:00:01] [Server thread/INFO]: Done (1.0s)! For help, type "help"'
        while true; do sleep 0.2; done
        """)

        let rt = ServerRuntime(serverID: rec.id)
        try rt.start(record: rec)
        try await wait("running") { rt.snapshot.status == .running }

        try rt.stop()
        // Must not sit in .stopping indefinitely. Generous timeout: the
        // watchdog waits gracefulStopSeconds before escalating.
        try await wait(
            "wedged server force-killed and settled",
            timeout: TimeInterval(ServerRuntime.gracefulStopSeconds) + 15
        ) {
            rt.snapshot.status == .stopped || rt.snapshot.status == .crashed
        }
        XCTAssertNil(rt.snapshot.pid)
        XCTAssertTrue(
            rt.lines.contains { $0.text.contains("Graceful stop timed out") },
            "watchdog should say out loud that it escalated"
        )
    }

    func testCrashIsDistinguishedFromCleanStop() async throws {
        let dir = makeTempDir("crash")
        let rec = fakeServer(dir, script: """
        #!/bin/sh
        echo '[12:00:01] [Server thread/INFO]: Done (1.0s)! For help, type "help"'
        sleep 0.3
        exit 1
        """)

        let rt = ServerRuntime(serverID: rec.id)
        try rt.start(record: rec)
        try await wait("crashed") { rt.snapshot.status == .crashed }
        XCTAssertEqual(rt.snapshot.exitCode, 1)
        XCTAssertFalse(rt.snapshot.stopRequested, "nobody asked it to stop — that's what makes it a crash")
    }

    func testEULAFlagIsSetFromConsoleOutput() async throws {
        let dir = makeTempDir("eula")
        let rec = fakeServer(dir, script: """
        #!/bin/sh
        echo '[12:00:00] [main/ERROR]: You need to agree to the EULA in order to run the server.'
        exit 0
        """)

        let rt = ServerRuntime(serverID: rec.id)
        try rt.start(record: rec)
        try await wait("needsEULA") { rt.snapshot.needsEULA }
    }

    func testStartingTwiceIsRejected() async throws {
        let dir = makeTempDir("double")
        let rec = fakeServer(dir, script: """
        #!/bin/sh
        echo '[12:00:01] [Server thread/INFO]: Done (1.0s)! For help, type "help"'
        while true; do sleep 0.2; done
        """)

        let rt = ServerRuntime(serverID: rec.id)
        try rt.start(record: rec)
        try await wait("running") { rt.snapshot.status == .running }
        XCTAssertThrowsError(try rt.start(record: rec))
        try? rt.forceKill()
    }

    func testStoppingAServerThatIsNotRunningThrows() {
        let rt = ServerRuntime(serverID: UUID())
        XCTAssertThrowsError(try rt.stop())
        XCTAssertThrowsError(try rt.writeStdin("hello"))
    }

    func testStartFailsClearlyWhenTheFolderIsMissing() {
        let rec = ServerRecord(
            name: "gone",
            path: "/definitely/not/a/real/folder",
            serverType: .vanilla,
            launchTarget: "server.jar",
            mcVersion: nil,
            javaPath: "java",
            ramMB: 1024
        )
        let rt = ServerRuntime(serverID: rec.id)
        XCTAssertThrowsError(try rt.start(record: rec)) { error in
            XCTAssertTrue("\(error)".contains("folder"))
        }
    }
}

@MainActor
final class ProcessManagerTests: XCTestCase {
    func testRuntimeIsStableAcrossLookups() {
        let pm = ProcessManager()
        let id = UUID()
        let a = pm.runtime(for: id)
        let b = pm.runtime(for: id)
        XCTAssertTrue(a === b, "same id must map to the same runtime, not a fresh one each call")
        XCTAssertFalse(pm.isRunning(id))
        XCTAssertFalse(pm.anyRunning)
        XCTAssertEqual(pm.runningCount, 0)
    }
}

final class ConsoleLineStyleTests: XCTestCase {
    func testSeverityDetection() {
        XCTAssertEqual(
            ConsoleLineStyle.severity(of: "[12:00:00] [Server thread/INFO]: hi", stream: .stdout),
            .info
        )
        XCTAssertEqual(
            ConsoleLineStyle.severity(of: "[12:00:00] [Server thread/WARN]: careful", stream: .stdout),
            .warn
        )
        XCTAssertEqual(
            ConsoleLineStyle.severity(of: "[12:00:00] [Server thread/ERROR]: boom", stream: .stdout),
            .error
        )
        // Bedrock's different format still classifies correctly
        XCTAssertEqual(
            ConsoleLineStyle.severity(of: "[2026-09-02 12:00:00:123 WARN] heads up", stream: .stdout),
            .warn
        )
        // stderr with no level tag is still an error — that's how JVM
        // stack traces arrive
        XCTAssertEqual(
            ConsoleLineStyle.severity(of: "\tat java.base/java.lang.Thread.run(Thread.java:840)", stream: .stderr),
            .error
        )
        XCTAssertEqual(ConsoleLineStyle.severity(of: "anything", stream: .system), .system)
    }

    func testPrefixSplitting() {
        let (prefix, message) = ConsoleLineStyle.splitPrefix("[12:00:00] [Server thread/INFO]: Done (1.0s)!")
        XCTAssertEqual(prefix, "[12:00:00] [Server thread/INFO]: ")
        XCTAssertEqual(message, "Done (1.0s)!")

        // no bracket prefix at all — must pass through untouched rather
        // than being mangled
        let (p2, m2) = ConsoleLineStyle.splitPrefix("plain line with no prefix")
        XCTAssertEqual(p2, "")
        XCTAssertEqual(m2, "plain line with no prefix")
    }
}
