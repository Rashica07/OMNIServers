import XCTest
@testable import craftpanel_Swift

final class GameServersTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appending(path: "cp-game-" + UUID().uuidString); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    private func touch(_ n: String, _ body: String = "") { try? body.write(to: dir.appending(path: n), atomically: true, encoding: .utf8) }
    private func read(_ n: String) -> String { (try? String(contentsOf: dir.appending(path: n), encoding: .utf8)) ?? "" }

    func testDetectsFiveMAndTerraria() {
        touch("FXServer.exe"); XCTAssertEqual(GameServers.inspect(at: dir)?.type, .fivem)
        try? FileManager.default.removeItem(at: dir.appending(path: "FXServer.exe"))
        touch("TerrariaServer.bin.osx"); XCTAssertEqual(GameServers.inspect(at: dir)?.type, .terraria)
    }
    func testLoneRunShIsNotFiveM() { touch("run.sh"); XCTAssertNil(GameServers.inspect(at: dir)) }
    func testFiveMFixCreatesConfigAndAsksForKey() {
        try? FileManager.default.createDirectory(at: dir.appending(path: "resources/chat"), withIntermediateDirectories: true)
        let r = GameServers.fix(type: .fivem, dir: dir, name: "My \"City\"")
        let cfg = read("server.cfg")
        XCTAssertTrue(cfg.contains("endpoint_add_udp")); XCTAssertTrue(cfg.contains("ensure chat")); XCTAssertFalse(cfg.contains("ensure spawnmanager"))
        XCTAssertTrue(cfg.contains("sv_hostname \"My City\""))
        XCTAssertTrue(r.todo.contains { $0.contains("licence key") })
    }
    func testFiveMFixKeepsKeyAndIsIdempotent() {
        try? FileManager.default.createDirectory(at: dir.appending(path: "resources"), withIntermediateDirectories: true)
        touch("server.cfg", "sv_licenseKeyToken \"abcdef1234567890\"\nendpoint_add_tcp \"0.0.0.0:30120\"\n")
        XCTAssertFalse(GameServers.fix(type: .fivem, dir: dir, name: "x").todo.contains { $0.contains("licence key") })
        let text = read("server.cfg"); XCTAssertTrue(text.contains("endpoint_add_udp"))
        XCTAssertTrue(GameServers.fix(type: .fivem, dir: dir, name: "x").done.isEmpty)
        XCTAssertEqual(read("server.cfg"), text)
    }
    func testTerrariaFix() {
        let r = GameServers.fix(type: .terraria, dir: dir, name: "Cool World!")
        let cfg = read("serverconfig.txt")
        XCTAssertTrue(cfg.contains("autocreate=2")); XCTAssertTrue(cfg.contains("worldname=CoolWorld")); XCTAssertTrue(cfg.contains("port=7777"))
        XCTAssertFalse(r.done.isEmpty); XCTAssertTrue(r.todo.isEmpty)
    }
    func testTerrariaUsesExistingWorld() {
        try? FileManager.default.createDirectory(at: dir.appending(path: "Worlds"), withIntermediateDirectories: true)
        touch("Worlds/Home.wld")
        _ = GameServers.fix(type: .terraria, dir: dir, name: "x")
        XCTAssertTrue(read("serverconfig.txt").contains("Home.wld")); XCTAssertFalse(read("serverconfig.txt").contains("autocreate"))
    }
    func testCommandsStatusBanner() {
        XCTAssertEqual(GameServers.stopCommand(.fivem), "quit"); XCTAssertEqual(GameServers.stopCommand(.terraria), "exit"); XCTAssertEqual(GameServers.stopCommand(.paper), "stop")
        XCTAssertEqual(GameServers.parseStatus(.terraria, output: "Server started"), .running)
        XCTAssertEqual(GameServers.parseStatus(.fivem, output: "hello"), .unknown)
        XCTAssertTrue(GameServers.banner(game: "FiveM").contains("MADE WITH OMNISERVERS"))
        XCTAssertFalse(GameServers.isPlatformSupported(.fivem)); XCTAssertFalse(ServerType.fivem.usesJava); XCTAssertTrue(ServerType.paper.usesJava)
    }
    func testDetectorFindsGameServer() async {
        touch("TerrariaServer.bin.osx")
        let r = await ServerDetector.detect(at: dir)
        XCTAssertTrue(r.detected); XCTAssertEqual(r.serverType, .terraria)
    }

    func testDetectsMacTerrariaAppBundle() {
        try? FileManager.default.createDirectory(at: dir.appending(path: "Terraria Server.app/Contents/MacOS"), withIntermediateDirectories: true)
        touch("Terraria Server.app/Contents/MacOS/TerrariaServer")
        let r = GameServers.inspect(at: dir)
        XCTAssertEqual(r?.type, .terraria); XCTAssertTrue(r?.launchTarget.hasSuffix("TerrariaServer") ?? false)
    }
    func testTerrariaConfigPathIsAbsolute() {
        let cfg = ServerConfig(path: dir, launchTarget: "x", javaPath: "", ramMB: 0, serverType: .terraria, jvmArgs: nil)
        XCTAssertEqual(GameServers.startCommand(config: cfg).arguments?[1], dir.appending(path: "serverconfig.txt").path)
    }
    func testParsesTerrariaNames() {
        XCTAssertEqual(GameInstaller.parseTerrariaFile(Data("[\"terraria-server-1458.zip\"]".utf8)), "terraria-server-1458.zip")
        XCTAssertNil(GameInstaller.parseTerrariaFile(Data("nope".utf8)))
    }
}
