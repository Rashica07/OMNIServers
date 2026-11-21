import XCTest
@testable import craftpanel_Swift

/// Real download + real server. Off unless `OMNI_LIVE=1` (needs network and about 100 MB).
final class OmniHostLiveTests: XCTestCase {
    func testDownloadStartPingAndStopTheRealEngine() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMNI_LIVE"] == "1",
                          "set OMNI_LIVE=1 to run")
        let engine = try await PumpkinEngine.ensureInstalled { _ in }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: engine.path))

        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let port: UInt16 = 25688
        try PumpkinConfig.render(.init(motd: "Live test", port: port, maxPlayers: 5, gamemode: "creative", difficulty: "easy", seed: ""))
            .write(to: dir.appending(path: "pumpkin.toml"), atomically: true, encoding: .utf8)

        // Offline mode through the same code Settings uses, plus the shared icon.
        try PumpkinConfig.apply(.init(onlineMode: false, motd: "Live test", maxPlayers: 5, gamemode: "creative", difficulty: "easy"), serverDir: dir)
        BrandingManager.installOmniHostIcon(serverDir: dir)
        let cfg = ServerConfig(path: dir, launchTarget: engine.path, javaPath: "", ramMB: 1024, serverType: .omnihost, jvmArgs: nil)
        let proc = try XCTUnwrap(OmniHostAdapter.startCommand(config: cfg))
        let out = Pipe(), inp = Pipe()
        proc.standardOutput = out; proc.standardError = out; proc.standardInput = inp
        try proc.run()
        defer { if proc.isRunning { proc.terminate() } }

        var seen = ""
        var running = false
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !running {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { try await Task.sleep(for: .milliseconds(200)); continue }
            seen += String(decoding: d, as: UTF8.self)
            running = OmniHostAdapter.parseStatus(seen) == .running
        }
        XCTAssertTrue(running, "never reported running. Output:\n\(seen)")
        XCTAssertFalse(seen.contains("\u{1B}["), "config turns colour off, so no ANSI codes")
        XCTAssertEqual(NetworkInfo.port(serverDir: dir), port)

        // A real Minecraft status ping.
        let r = try Subprocess.run("/usr/bin/python3", ["-I", "-c", """
        import socket,struct
        def vi(n):
            o=b''
            while True:
                b=n&0x7f;n>>=7
                o+=bytes([b|(0x80 if n else 0)])
                if not n:return o
        def pkt(b):return vi(len(b))+b
        s=socket.create_connection(('127.0.0.1',\(port)),timeout=5)
        h=b'\\x00'+vi(777)+vi(9)+b'localhost'+struct.pack('>H',\(port))+vi(1)
        s.sendall(pkt(h)+pkt(b'\\x00'))
        d=s.recv(65536)
        print('Live test' in d.decode('latin1') and '26.3' in d.decode('latin1'))
        """], timeout: 15)
        XCTAssertEqual(r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "True", r.stderrString)

        // Offline login: the server answers Login Start with Set Compression (id 3), not an Encryption Request (id 1).
        let login = try Subprocess.run("/usr/bin/python3", ["-I", "-c", """
        import socket,struct,uuid
        def vi(n):
            o=b''
            while True:
                b=n&0x7f;n>>=7
                o+=bytes([b|(0x80 if n else 0)])
                if not n:return o
        def pkt(b):return vi(len(b))+b
        s=socket.create_connection(('127.0.0.1',\(port)),timeout=5)
        s.sendall(pkt(b'\\x00'+vi(777)+vi(9)+b'localhost'+struct.pack('>H',\(port))+vi(2))+pkt(b'\\x00'+vi(4)+b'Kiqa'+uuid.uuid4().bytes))
        s.recv(1)
        print(s.recv(1)[0])
        """], timeout: 15)
        XCTAssertEqual(login.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "3", "offline login not accepted: \(login.stderrString)")
        // The console view: short OMNIHost lines, no engine name, no banners.
        let shown = seen.split(separator: "\n").compactMap { OmniHostLog.simplify(String($0)) }
        XCTAssertTrue(shown.contains { $0.contains("Ready. Join on port \(port)") }, "\(shown)")
        XCTAssertFalse(shown.joined().lowercased().contains("pumpkin"), "\(shown)")
        XCTAssertLessThanOrEqual(shown.count, 6, "console should stay short: \(shown)")
        print("CONSOLE:\n" + shown.joined(separator: "\n"))
        try inp.fileHandleForWriting.write(contentsOf: Data((GameServers.stopCommand(.omnihost) + "\n").utf8))
        let stopBy = Date().addingTimeInterval(15)
        while proc.isRunning, Date() < stopBy { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertFalse(proc.isRunning, "did not stop on 'stop'")
        XCTAssertEqual(proc.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "world/level.dat").path))
    }
}

/// Moves a copy of a real Java server (path in `OMNI_LIVE_SRC`) and starts it on the real engine.
final class OmniHostLiveTransferTests: XCTestCase {
    func testTransferARealJavaServerAndStartIt() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OMNI_LIVE"] == "1" && env["OMNI_LIVE_SRC"] != nil, "set OMNI_LIVE=1 and OMNI_LIVE_SRC")
        let src = URL(fileURLWithPath: env["OMNI_LIVE_SRC"]!)
        let engine = try await PumpkinEngine.ensureInstalled { _ in }
        let dest = FileManager.default.temporaryDirectory.appending(path: "cp-live-xfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        let keep = env["OMNI_LIVE_KEEP"]   // optional: where to leave the moved server for a manual join check
        defer {
            if let keep { try? FileManager.default.removeItem(atPath: keep); try? FileManager.default.copyItem(at: dest, to: URL(fileURLWithPath: keep)) }
            try? FileManager.default.removeItem(at: dest)
        }
        let t0 = Date()
        let plan = try OmniHostTransfer.plan(sourceDir: src, name: "Real")
        try await OmniHostTransfer.perform(plan, to: dest)
        print("TRANSFER took \(Date().timeIntervalSince(t0))s, world \(OmniHostTransfer.format(plan.worldBytes)), mods \(plan.modCount)")
        // Spare port so this never clashes with a server that is really running.
        let toml = dest.appending(path: "pumpkin.toml")
        try PumpkinConfig.setting(in: String(contentsOf: toml, encoding: .utf8), section: "networking.java", key: "address", raw: "\"0.0.0.0:25689\"")
            .write(to: toml, atomically: true, encoding: .utf8)

        let cfg = ServerConfig(path: dest, launchTarget: engine.path, javaPath: "", ramMB: 1024, serverType: .omnihost, jvmArgs: nil)
        let proc = try XCTUnwrap(OmniHostAdapter.startCommand(config: cfg))
        let out = Pipe(), inp = Pipe()
        proc.standardOutput = out; proc.standardError = out; proc.standardInput = inp
        try proc.run()
        defer { if proc.isRunning { proc.terminate() } }
        var seen = "", running = false
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !running {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { try await Task.sleep(for: .milliseconds(200)); continue }
            seen += String(decoding: d, as: UTF8.self)
            running = OmniHostAdapter.parseStatus(seen) == .running
        }
        XCTAssertTrue(running, "never ready:\n\(seen)")
        XCTAssertTrue(seen.contains("Converted"), "the world should have been converted:\n\(seen)")
        print("START took \(Date().timeIntervalSince(t0))s total")
        try inp.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
        let stopBy = Date().addingTimeInterval(30)
        while proc.isRunning, Date() < stopBy { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertFalse(proc.isRunning)
        XCTAssertEqual(proc.terminationStatus, 0)
    }
}
