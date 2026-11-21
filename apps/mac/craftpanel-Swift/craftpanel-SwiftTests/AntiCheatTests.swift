import XCTest
@testable import craftpanel_Swift

/// Direct port of `anticheat.rs`'s own `#[cfg(test)] mod tests`.
final class AntiCheatTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-ac-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func testAdvisesWhenPublicAndUnprotected() throws {
        let d = tempDir("advise")
        try FileManager.default.createDirectory(at: d.appending(path: "plugins"), withIntermediateDirectories: true)

        let a = AntiCheat.advise(serverDir: d, serverType: .paper, isPublic: true)
        XCTAssertTrue(a.warn)
        XCTAssertTrue(a.recommended.contains { $0.slug == "grimac" })

        try Data("x".utf8).write(to: d.appending(path: "plugins/GrimAC-2.3.jar"))
        let a2 = AntiCheat.advise(serverDir: d, serverType: .paper, isPublic: true)
        XCTAssertFalse(a2.warn)
        XCTAssertEqual(a2.installed, ["GrimAC"])
    }

    func testSuspicionCountsMovementFlagsAndRejoins() throws {
        let d = tempDir("suspicion")
        try FileManager.default.createDirectory(at: d.appending(path: "logs"), withIntermediateDirectories: true)
        let log = """
        [10:00:00] [Server thread/WARN]: Hacker123 moved too quickly! -12.0,0.0,3.4
        [10:00:01] [Server thread/WARN]: Hacker123 moved wrongly!
        [10:00:02] [Server thread/INFO]: [GrimAC] Hacker123 flagged Simulation (A) VL: 12
        [10:05:00] [Server thread/INFO]: Bob joined the game
        [10:05:01] [Server thread/INFO]: Bob left the game
        [10:05:02] [Server thread/INFO]: Bob joined the game
        [10:05:03] [Server thread/INFO]: Bob left the game
        [10:05:04] [Server thread/INFO]: Bob joined the game

        """
        try log.write(to: d.appending(path: "logs/latest.log"), atomically: true, encoding: .utf8)

        let s = AntiCheat.suspicion(serverDir: d)
        let h = try XCTUnwrap(s.first { $0.name == "Hacker123" })
        XCTAssertEqual(h.flags, 3)
        XCTAssertFalse(h.samples.isEmpty)
        let b = s.first { $0.name == "Bob" }
        XCTAssertTrue((b?.rejoins ?? 0) >= 2)
    }
}
