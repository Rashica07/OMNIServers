import XCTest
@testable import craftpanel_Swift

final class ServerSettingsTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func dirWith(_ contents: String) -> String {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-settings-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try! contents.write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        tempDirs.append(d)
        return d.path
    }

    func testReadsCommonAdvancedAndFlagsOfflineMode() {
        let dir = dirWith("online-mode=false\ndifficulty=hard\nsimulation-distance=6\n")
        let s = ServerSettings.read(serverDir: dir, serverType: .paper)
        XCTAssertTrue(s.present)
        let om = s.common.first { $0.key == "online-mode" }!
        XCTAssertEqual(om.value, "false")
        XCTAssertNotNil(om.note)
        let sim = s.advanced.first { $0.key == "simulation-distance" }!
        XCTAssertEqual(sim.value, "6")
        XCTAssertNotNil(sim.help)
    }

    func testBedrockGetsBedrockShapedFieldsNotJavaOnes() {
        let dir = dirWith("server-name=My Realm\ngamemode=creative\nallow-cheats=true\n")
        let s = ServerSettings.read(serverDir: dir, serverType: .bedrock)
        XCTAssertTrue(s.present)
        let name = s.common.first { $0.key == "server-name" }!
        XCTAssertEqual(name.value, "My Realm")
        let gm = s.common.first { $0.key == "gamemode" }!
        XCTAssertEqual(gm.value, "creative")
        // no "spectator" offered -- not a real Bedrock game mode
        XCTAssertFalse(gm.options.contains("spectator"))
        // Java-only keys are absent entirely, not just empty
        XCTAssertTrue(s.common.allSatisfy { $0.key != "motd" && $0.key != "pvp" })
        XCTAssertTrue(s.advanced.allSatisfy { $0.key != "query.port" && $0.key != "level-type" })
    }

    func testApplyIsSurgical() throws {
        let dir = dirWith("#header\nonline-mode=false\npvp=true\nmotd=Old\n")
        let changed = try ServerSettings.apply(serverDir: dir, changes: [("motd", "New"), ("pvp", "true")])
        XCTAssertEqual(changed, ["motd"])
        let out = try String(contentsOf: URL(fileURLWithPath: dir).appending(path: "server.properties"), encoding: .utf8)
        XCTAssertTrue(out.contains("#header\n"))
        XCTAssertTrue(out.contains("online-mode=false\n"))
        XCTAssertTrue(out.contains("motd=New\n"))
    }

    func testRejectsBadKeys() {
        let dir = dirWith("motd=x\n")
        XCTAssertThrowsError(try ServerSettings.apply(serverDir: dir, changes: [("../evil", "1")]))
    }

    func testAbsentWhenNoPropertiesFile() {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-settings-missing-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        let s = ServerSettings.read(serverDir: d.path, serverType: .vanilla)
        XCTAssertFalse(s.present)
        XCTAssertTrue(s.common.isEmpty)
    }
}
