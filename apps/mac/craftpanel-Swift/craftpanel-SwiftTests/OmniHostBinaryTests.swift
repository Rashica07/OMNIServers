import XCTest
@testable import craftpanel_Swift

final class OmniHostAdapterTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-omnihost-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeExecutable(at f: URL, executable: Bool = true) {
        try! "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: f.path)
    }

    func testDetectsPumpkinAndLegacyConfigFolders() {
        let a = tempDir(), b = tempDir(), c = tempDir()
        FileManager.default.createFile(atPath: a.appending(path: "pumpkin.toml").path, contents: Data())
        FileManager.default.createFile(atPath: b.appending(path: "omnihost.toml").path, contents: Data())
        XCTAssertNotNil(OmniHostAdapter.inspect(at: a, engine: nil))
        XCTAssertNotNil(OmniHostAdapter.inspect(at: b, engine: nil))
        XCTAssertNil(OmniHostAdapter.inspect(at: c, engine: nil))
    }

    func testResolveBinaryPrefersStoredAbsolutePath() {
        let dir = tempDir(), engineDir = tempDir()
        let stored = engineDir.appending(path: "stored"), installed = engineDir.appending(path: "installed")
        makeExecutable(at: stored); makeExecutable(at: installed)
        XCTAssertEqual(OmniHostAdapter.resolveBinary(launchTarget: stored.path, serverDir: dir, engine: installed)?.path, stored.path)
    }

    func testResolveBinaryFallsBackToInstalledEngineWhenStoredFileIsGone() {
        let dir = tempDir(), engineDir = tempDir()
        let installed = engineDir.appending(path: "installed")
        makeExecutable(at: installed)
        XCTAssertEqual(OmniHostAdapter.resolveBinary(launchTarget: "/gone/pumpkin", serverDir: dir, engine: installed)?.path, installed.path)
        XCTAssertNil(OmniHostAdapter.resolveBinary(launchTarget: "/gone/pumpkin", serverDir: dir, engine: nil))
    }

    func testResolveBinaryFindsRelativeFileInServerFolder() {
        let dir = tempDir()
        makeExecutable(at: dir.appending(path: "pumpkin"))
        XCTAssertEqual(OmniHostAdapter.resolveBinary(launchTarget: "pumpkin", serverDir: dir, engine: nil)?.path, dir.appending(path: "pumpkin").path)
    }

    func testNonExecutableFileDoesNotCount() {
        let dir = tempDir()
        makeExecutable(at: dir.appending(path: "pumpkin"), executable: false)
        XCTAssertNil(OmniHostAdapter.resolveBinary(launchTarget: "pumpkin", serverDir: dir, engine: nil))
    }

    func testStartCommandRunsInServerFolderWithNoArguments() throws {
        let dir = tempDir(), engineDir = tempDir()
        let engine = engineDir.appending(path: "pumpkin"); makeExecutable(at: engine)
        let cfg = ServerConfig(path: dir, launchTarget: engine.path, javaPath: "", ramMB: 2048, serverType: .omnihost, jvmArgs: nil)
        let p = try XCTUnwrap(OmniHostAdapter.startCommand(config: cfg, engine: nil))
        XCTAssertEqual(p.executableURL?.path, engine.path)
        XCTAssertEqual(p.currentDirectoryURL?.path, dir.path)
        XCTAssertEqual(p.arguments, [])
    }

    func testStartCommandIsNilWithoutAnyEngine() {
        let cfg = ServerConfig(path: tempDir(), launchTarget: "/gone/pumpkin", javaPath: "", ramMB: 2048, serverType: .omnihost, jvmArgs: nil)
        XCTAssertNil(OmniHostAdapter.startCommand(config: cfg, engine: nil))
    }

    // Lines copied from a real run of the 0.2.2+26.3-26.60 binary.
    func testParseStatusFromRealPumpkinLogLines() {
        XCTAssertEqual(OmniHostAdapter.parseStatus("11:55:09  INFO Loading minecraft:overworld"), .unknown)
        XCTAssertEqual(OmniHostAdapter.parseStatus("11:55:09  INFO Server is now running. Connect using port: Java Edition: 0.0.0.0:25599"), .running)
        XCTAssertEqual(OmniHostAdapter.parseStatus("11:55:13  WARN Received interrupt signal; stopping server..."), .stopping)
        XCTAssertEqual(OmniHostAdapter.parseStatus("thread 'main' panicked at src/main.rs:1:1"), .crashed)
    }

    func testServerTypeUsesNoJava() {
        XCTAssertFalse(ServerType.omnihost.usesJava)
    }
}
