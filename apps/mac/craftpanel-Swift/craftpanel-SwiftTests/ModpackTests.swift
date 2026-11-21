import XCTest
@testable import craftpanel_Swift

final class ModpackTests: XCTestCase {
    func testSafeRelativePath() {
        XCTAssertTrue(Modpacks.safeRelativePath("mods/sodium.jar"))
        XCTAssertTrue(Modpacks.safeRelativePath("config/nested/dir/file.toml"))
        for bad in ["../../../etc/passwd", "mods/../../../evil.jar", "/etc/passwd", "", "a//b", "a\\b"] {
            XCTAssertFalse(Modpacks.safeRelativePath(bad), bad)
        }
    }

    func testDownloadHostAllowlist() {
        XCTAssertNotNil(Modpacks.downloadAllowed("https://cdn.modrinth.com/data/x/y.jar"))
        XCTAssertNil(Modpacks.downloadAllowed("http://cdn.modrinth.com/data/x/y.jar"))
        XCTAssertNil(Modpacks.downloadAllowed("https://evil.example.com/y.jar"))
    }

    func testServerWantsDefaultsTrue() throws {
        let json = #"{"files":[{"path":"a","hashes":{},"downloads":[]},{"path":"b","hashes":{},"env":{"server":"unsupported"},"downloads":[]}],"dependencies":{}}"#
        let idx = try JSONDecoder().decode(Modpacks.Index.self, from: Data(json.utf8))
        XCTAssertEqual(idx.files.filter(Modpacks.serverWants).map(\.path), ["a"])
    }

    func testMergeSkipsSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "cp-mp-\(UUID().uuidString)")
        let src = root.appending(path: "src"), dst = root.appending(path: "dst"), outside = root.appending(path: "outside")
        for d in [src.appending(path: "config"), dst, outside] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        try "ok".write(to: src.appending(path: "config/a.toml"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: src.appending(path: "escape"), withDestinationURL: outside)
        try Modpacks.mergeRegularFiles(from: src, into: dst)
        XCTAssertTrue(fm.fileExists(atPath: dst.appending(path: "config/a.toml").path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: dst.appending(path: "escape").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appending(path: "escape").path))
    }

    func testStartingSettingsApplied() throws {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appending(path: "cp-ss-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: d) }
        try "online-mode=true\nserver-port=25565\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        Provisioner.applyStartingSettings(dir: d, bedrock: false, port: 25570, seed: " 42 ", gamemode: "creative",
                                          difficulty: "bogus", motd: "hi", maxPlayers: 8)
        let p = Properties.load(dir: d)
        XCTAssertEqual(p.get("server-port"), "25570")
        XCTAssertEqual(p.get("rcon.port"), "25580")
        XCTAssertEqual(p.get("level-seed"), "42")
        XCTAssertEqual(p.get("gamemode"), "creative")
        XCTAssertNil(p.get("difficulty"))
        XCTAssertEqual(p.get("online-mode"), "true")
        XCTAssertNotNil(Provisioner.pickFreePort(taken: []))
    }
}
