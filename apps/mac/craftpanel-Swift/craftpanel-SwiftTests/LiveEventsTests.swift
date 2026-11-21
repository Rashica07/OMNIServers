import XCTest
import Network
@testable import craftpanel_Swift

final class LiveEventsTests: XCTestCase {
    func testParsesAllLogFormats() {
        XCTAssertEqual(LiveEvent.parse("[12:00:01] [Server thread/INFO]: Steve joined the game"), .join("Steve"))
        XCTAssertEqual(LiveEvent.parse("[12:00:01 INFO]: Alex left the game"), .leave("Alex"))
        XCTAssertEqual(LiveEvent.parse("[12:00:01] [Server thread/INFO] [minecraft/MinecraftServer]: Steve joined the game"), .join("Steve"))
        XCTAssertEqual(LiveEvent.parse("[12:00:02] [Server thread/INFO]: <Steve> hello there"), .chat(from: "Steve", text: "hello there"))
        XCTAssertEqual(LiveEvent.parse("[12:00:02] [Server thread/INFO]: [Not Secure] <Steve> hi"), .chat(from: "Steve", text: "hi"))
        XCTAssertEqual(LiveEvent.parse("[12:00:02 INFO]: \u{1B}[33m<Alex> yo\u{1B}[0m"), .chat(from: "Alex", text: "yo"))
        XCTAssertEqual(LiveEvent.parse("[12:00:03] [Server thread/INFO]: [Server] restarting soon"), .broadcast(from: "Server", text: "restarting soon"))
        XCTAssertEqual(LiveEvent.parse("[12:00:04] [Server thread/INFO]: Steve has made the advancement [Stone Age]"), .advancement(player: "Steve", title: "Stone Age"))
        XCTAssertEqual(LiveEvent.parse("[12:00:04] [Server thread/INFO]: .BedrockGuy joined the game"), .join(".BedrockGuy"))
    }

    func testChatCantForgeEvents() {
        XCTAssertEqual(LiveEvent.parse("[12:00:02] [Server thread/INFO]: <Eve> Bob joined the game"), .chat(from: "Eve", text: "Bob joined the game"))
        XCTAssertNil(LiveEvent.parse("[12:00:02] [Server thread/INFO]: Some thing joined the game"))
        XCTAssertNil(LiveEvent.parse("[12:00:02] [Server thread/INFO]: Done (3.2s)! For help, type \"help\""))
        XCTAssertNil(LiveEvent.parse("[12:00:02] [Server thread/INFO]: [Steve: Gave 1 [Stone] to Steve]"))
    }

    @MainActor func testRuntimeTracksOnlineAndChat() {
        let rt = ServerRuntime(serverID: UUID())
        rt.push(.stdout, "[12:00:01] [Server thread/INFO]: Steve joined the game")
        rt.push(.stdout, "[12:00:01] [Server thread/INFO]: Alex joined the game")
        rt.push(.stdout, "[12:00:02] [Server thread/INFO]: <Steve> hi")
        rt.push(.system, "[12:00:02] [Server thread/INFO]: Mallory joined the game")   // our own lines don't count
        rt.push(.stdout, "[12:00:03] [Server thread/INFO]: Steve left the game")
        XCTAssertEqual(rt.online, ["Alex"])
        XCTAssertEqual(rt.chat.map(\.kind), [.join, .join, .chat, .leave])
    }

    func testTellrawJSONEscapes() throws {
        let json = ChatHistory.tellrawJSON(name: "Host", message: "say \"hi\" \\ ]}\nnext")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        XCTAssertEqual((parsed[2] as? [String: String])?["text"], "say \"hi\" \\ ]} next")
        XCTAssertFalse(json.contains("\n"))
    }

    func testLogTailerFollowsAppendsAndRotation() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "logs"), withIntermediateDirectories: true)
        let log = dir.appending(path: "logs/latest.log")
        try "old line\n".write(to: log, atomically: true, encoding: .utf8)
        var tail = LogTailer(serverDir: dir)
        XCTAssertEqual(tail.poll(), [])
        let h = try FileHandle(forWritingTo: log); try h.seekToEnd()
        try h.write(contentsOf: Data("new one\npart".utf8))
        XCTAssertEqual(tail.poll(), ["new one"])
        try h.write(contentsOf: Data("ial\n".utf8)); try h.close()
        XCTAssertEqual(tail.poll(), ["partial"])
        try "fresh\n".write(to: log, atomically: true, encoding: .utf8)   // rotated: shorter file
        XCTAssertEqual(tail.poll(), ["fresh"])
    }

    func testChatHistoryFromLatestLog() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "logs"), withIntermediateDirectories: true)
        try """
        [09:00:00] [Server thread/INFO]: Starting minecraft server
        [09:01:00] [Server thread/INFO]: Steve joined the game
        [09:02:30] [Server thread/INFO]: <Steve> morning
        """.write(to: dir.appending(path: "logs/latest.log"), atomically: true, encoding: .utf8)
        let past = ChatHistory.load(serverDir: dir)
        XCTAssertEqual(past.map(\.kind), [.join, .chat])
        XCTAssertEqual(past.last?.text, "morning")
        XCTAssertEqual(Calendar.current.component(.minute, from: past.last!.date), 2)
    }
}

final class BlueMapTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testSupportAndPaths() throws {
        XCTAssertFalse(BlueMap.supported(.vanilla))
        XCTAssertFalse(BlueMap.supported(.bedrock))
        XCTAssertTrue(BlueMap.supported(.fabric))
        let d = try tempDir()
        XCTAssertEqual(BlueMap.configDir(d, type: .paper).lastPathComponent, "BlueMap")
        XCTAssertEqual(BlueMap.configDir(d, type: .fabric).path, d.appending(path: "config/bluemap").path)
    }

    func testConfigureEditsExistingFilesAndKeepsTheRest() throws {
        let d = try tempDir()
        let cfg = BlueMap.configDir(d, type: .fabric)
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try "# By changing accept-download: …\naccept-download: false\nrender-thread-count: 1\n".write(to: cfg.appending(path: "core.conf"), atomically: true, encoding: .utf8)
        try "enabled: true\nport: 8100\nsse-enabled: true\n".write(to: cfg.appending(path: "webserver.conf"), atomically: true, encoding: .utf8)
        XCTAssertFalse(BlueMap.consentGiven(d, type: .fabric))
        try BlueMap.configure(d, type: .fabric, port: 8102)
        let core = try String(contentsOf: cfg.appending(path: "core.conf"), encoding: .utf8)
        XCTAssertTrue(core.contains("accept-download: true"))
        XCTAssertTrue(core.contains("# By changing accept-download: …"))
        XCTAssertTrue(core.contains("render-thread-count: 1"))
        XCTAssertTrue(BlueMap.consentGiven(d, type: .fabric))
        XCTAssertEqual(BlueMap.port(d, type: .fabric), 8102)
        XCTAssertTrue(try String(contentsOf: cfg.appending(path: "webserver.conf"), encoding: .utf8).contains("sse-enabled: true"))
    }

    func testConfigureWritesMinimalFilesAndPortsDontClash() throws {
        let a = try tempDir(), b = try tempDir()
        try BlueMap.configure(a, type: .paper, port: 8100)
        XCTAssertTrue(BlueMap.consentGiven(a, type: .paper))
        try FileManager.default.createDirectory(at: a.appending(path: "plugins"), withIntermediateDirectories: true)
        try Data().write(to: a.appending(path: "plugins/bluemap-5.28-paper.jar"))
        XCTAssertTrue(BlueMap.isInstalled(a, type: .paper))
        XCTAssertFalse(BlueMap.isInstalled(b, type: .fabric))
        XCTAssertGreaterThan(BlueMap.pickPort(otherServers: [(a, .paper)]), 8100)
    }

    /// The Map tab talks plain HTTP to 127.0.0.1 — make sure App Transport
    /// Security lets the app do that.
    func testLocalHTTPReachable() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        let ready = expectation(description: "ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        let port = Int(listener.port!.rawValue)
        let isUp = await BlueMap.isUp(port: port)
        XCTAssertTrue(isUp)
        listener.cancel()
        let isUpAfter = await BlueMap.isUp(port: port)
        XCTAssertFalse(isUpAfter)
    }
}
