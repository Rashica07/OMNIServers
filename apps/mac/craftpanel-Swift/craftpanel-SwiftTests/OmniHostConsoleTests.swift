import XCTest
@testable import craftpanel_Swift

final class OmniHostLogTests: XCTestCase {
    private let esc = "\u{1B}[2m"
    private let reset = "\u{1B}[0m"

    // Real lines from the 0.2.2+26.3-26.60 binary (with its colour codes).
    func testStartupBecomesShortOMNIHostLines() {
        XCTAssertEqual(OmniHostLog.simplify("\(esc)11:54:40\(reset) \u{1B}[32m INFO\(reset) Starting Pumpkin 0.2.2+26.3-26.60 Java Minecraft (Protocol 777) | 1.26.60 Bedrock (Protocol 2225)"),
                       "[11:54:40] Starting OMNIHost (Minecraft 26.3)")
        XCTAssertEqual(OmniHostLog.simplify("11:54:41  INFO All worlds loaded successfully."), "[11:54:41] World loaded")
        XCTAssertEqual(OmniHostLog.simplify("11:54:41  INFO Server is now running. Connect using port: Java Edition: 0.0.0.0:25599 | Bedrock Edition: 0.0.0.0:19132"),
                       "[11:54:41] Ready. Join on port 25599")
        XCTAssertEqual(OmniHostLog.simplify("11:54:41  INFO Server is now running. Connect using port: Java Edition: 0.0.0.0:25601"), "[11:54:41] Ready. Join on port 25601")
        XCTAssertEqual(OmniHostLog.simplify("11:54:40  WARN No level.dat in world, creating a new world with seed 179675"), "[11:54:40] Warning: Creating a new world")
    }

    func testShutdownBecomesShortLines() {
        XCTAssertEqual(OmniHostLog.simplify("11:55:13  WARN Received interrupt signal; stopping server..."), "[11:55:13] Warning: Stopping…")
        XCTAssertEqual(OmniHostLog.simplify("11:55:13  INFO Completed save!"), "[11:55:13] World saved")
        XCTAssertEqual(OmniHostLog.simplify("11:55:13  INFO The server has stopped."), "[11:55:13] Stopped")
    }

    func testNoiseIsDropped() {
        for line in [
            "11:54:40  INFO Report issues on https://github.com/Pumpkin-MC/Pumpkin/issues",
            "11:54:40  INFO Join our Discord for community support: https://discord.gg/x",
            "11:54:40  INFO Consider Donating to https://pumpkinmc.org/donate/",
            "11:54:40  WARN Pumpkin is currently under heavy development!",
            "11:54:41  INFO Loading minecraft:the_nether",
            "11:54:41  INFO Loaded 198 embedded test instance(s)",
            "11:54:41  INFO Bedrock NetherNet ICE is listening on 0.0.0.0:19132",
            "11:54:41  WARN The input is not a TTY; falling back to simple logger and ignoring `use_tty` setting",
            "11:54:41  INFO Anonymous server telemetry is enabled. Sending periodic heartbeats",
            "11:55:13  INFO Flushing chunk data to disk for world...",
            "11:55:13  INFO schedule: waiting for 0 generation tasks to finish",
            "11:55:13  DEBUG something internal",
            "   ",
        ] { XCTAssertNil(OmniHostLog.simplify(line), line) }
    }

    func testNameIsNeverPumpkinAndOtherLinesAreKept() {
        XCTAssertEqual(OmniHostLog.simplify("12:00:01  ERROR Pumpkin failed to bind PumpkinMC port"), "[12:00:01] Error: OMNIHost failed to bind OMNIHost port")
        XCTAssertEqual(OmniHostLog.simplify("12:00:02  INFO Kiqa joined the game"), "[12:00:02] Kiqa joined the game")
        XCTAssertEqual(OmniHostLog.simplify("thread 'main' panicked at pumpkin/src/main.rs:1"), "thread 'main' panicked at OMNIHost/src/main.rs:1")
    }

    func testShortFormatStillFeedsPlayersAndChat() {
        XCTAssertEqual(LiveEvent.parse("[12:00:02] Kiqa joined the game"), .join("Kiqa"))
        XCTAssertEqual(LiveEvent.parse("[12:00:09] Kiqa left the game"), .leave("Kiqa"))
        XCTAssertEqual(LiveEvent.parse("[12:00:10] <Kiqa> hello"), .chat(from: "Kiqa", text: "hello"))
        XCTAssertNil(LiveEvent.parse("[12:00:11] World loaded"))
        XCTAssertEqual(LiveEvent.parse("[12:00:02 INFO]: Kiqa joined the game"), .join("Kiqa"), "old format still works")
    }
}

final class PumpkinConfigEditTests: XCTestCase {
    private let sample = """
    seed = "1"
    default_difficulty = "Normal"
    default_gamemode = "Survival"

    [networking.java]
    address = "0.0.0.0:25565"
    online_mode = true # sign in
    max_players = 1000
    motd = "Old \\"quoted\\" name"

    [networking.bedrock]
    online_mode = true
    """

    func testReadsTheEditableSettings() {
        let e = PumpkinConfig.read(toml: sample)
        XCTAssertTrue(e.onlineMode)
        XCTAssertEqual(e.maxPlayers, 1000)
        XCTAssertEqual(e.gamemode, "survival")
        XCTAssertEqual(e.difficulty, "normal")
        XCTAssertEqual(e.motd, "Old \"quoted\" name")
    }

    func testOfflineModeChangesOnlyTheJavaSection() {
        let out = PumpkinConfig.setting(in: sample, section: "networking.java", key: "online_mode", raw: "false")
        XCTAssertEqual(PumpkinConfig.rawValue(in: out, section: "networking.java", key: "online_mode"), "false")
        XCTAssertEqual(PumpkinConfig.rawValue(in: out, section: "networking.bedrock", key: "online_mode"), "true", "Bedrock's own key is untouched")
        XCTAssertFalse(PumpkinConfig.read(toml: out).onlineMode)
        // Everything else is byte for byte the same.
        XCTAssertEqual(out.components(separatedBy: "\n").filter { !$0.contains("online_mode") },
                       sample.components(separatedBy: "\n").filter { !$0.contains("online_mode") })
    }

    func testMissingKeysAreAddedInTheRightPlace() {
        var out = PumpkinConfig.setting(in: "[networking.java]\naddress = \"0.0.0.0:1\"\n\n[x]\na = 1\n", section: "networking.java", key: "online_mode", raw: "false")
        XCTAssertEqual(out, "[networking.java]\naddress = \"0.0.0.0:1\"\nonline_mode = false\n\n[x]\na = 1\n")
        out = PumpkinConfig.setting(in: "[x]\na = 1\n", section: "", key: "favicon_path", raw: "\"server-icon.png\"")
        XCTAssertEqual(out, "favicon_path = \"server-icon.png\"\n[x]\na = 1\n", "top-level keys go before the first section")
        out = PumpkinConfig.setting(in: "a = 1\n", section: "networking.java", key: "online_mode", raw: "false")
        XCTAssertTrue(out.hasSuffix("[networking.java]\nonline_mode = false\n"))
    }

    func testApplyRoundTripsThroughTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-pk-edit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sample.write(to: dir.appending(path: "pumpkin.toml"), atomically: true, encoding: .utf8)
        let edit = PumpkinConfig.Editable(onlineMode: false, motd: "My \"world\"", maxPlayers: 8, gamemode: "creative", difficulty: "hard")
        try PumpkinConfig.apply(edit, serverDir: dir)
        XCTAssertEqual(PumpkinConfig.read(serverDir: dir), edit)
        XCTAssertEqual(PumpkinConfig.javaPort(serverDir: dir), 25565, "port is untouched")
    }

    func testRenderedConfigHasFaviconAndReadsBack() throws {
        let t = PumpkinConfig.render(.init(motd: "Hi", port: 25570, maxPlayers: 4, gamemode: "creative", difficulty: "easy", seed: ""))
        XCTAssertEqual(PumpkinConfig.rawValue(in: t, section: "", key: "favicon_path"), "\"server-icon.png\"")
        XCTAssertEqual(PumpkinConfig.read(toml: t), .init(onlineMode: true, motd: "Hi", maxPlayers: 4, gamemode: "creative", difficulty: "easy"))
    }

    func testEnsureFaviconOnlyAddsWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-pk-fav-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appending(path: "pumpkin.toml")
        try "[networking.java]\naddress = \"0.0.0.0:1\"\n".write(to: f, atomically: true, encoding: .utf8)
        PumpkinConfig.ensureFavicon(serverDir: dir)
        XCTAssertEqual(PumpkinConfig.rawValue(in: try String(contentsOf: f, encoding: .utf8), section: "", key: "favicon_path"), "\"server-icon.png\"")
        try "favicon_path = \"mine.png\"\n".write(to: f, atomically: true, encoding: .utf8)
        PumpkinConfig.ensureFavicon(serverDir: dir)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "favicon_path = \"mine.png\"\n")
    }
}

final class OmniHostIconTests: XCTestCase {
    func testDefaultIconIsWrittenOnceAndNeverReplacesTheUsersOwn() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-pk-icon-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTSkipIf(NSImage(named: NSImage.applicationIconName) == nil, "no app icon in this test host")
        XCTAssertTrue(BrandingManager.installOmniHostIcon(serverDir: dir))
        let icon = dir.appending(path: "server-icon.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: icon)))
        XCTAssertEqual(rep.pixelsWide, 64); XCTAssertEqual(rep.pixelsHigh, 64)
        try Data("user".utf8).write(to: icon)
        XCTAssertFalse(BrandingManager.installOmniHostIcon(serverDir: dir))
        XCTAssertEqual(try Data(contentsOf: icon), Data("user".utf8))
    }
}
