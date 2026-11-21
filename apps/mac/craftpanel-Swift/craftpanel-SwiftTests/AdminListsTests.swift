import XCTest
@testable import craftpanel_Swift

final class AdminListsTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-admin-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func testParsesAllThreeLists() throws {
        let d = makeTempDir()
        try #"[{"uuid":"x","name":"Steve","level":4}]"#.write(to: d.appending(path: "ops.json"), atomically: true, encoding: .utf8)
        try #"[{"uuid":"y","name":"Alex"}]"#.write(to: d.appending(path: "whitelist.json"), atomically: true, encoding: .utf8)
        try #"[{"uuid":"z","name":"Griefer","reason":"grief"}]"#.write(to: d.appending(path: "banned-players.json"), atomically: true, encoding: .utf8)
        try "white-list=true\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)

        let l = AdminLists.read(serverDir: d.path)
        XCTAssertEqual(l.ops, ["Steve"])
        XCTAssertEqual(l.whitelist, ["Alex"])
        XCTAssertEqual(l.banned.first?.name, "Griefer")
        XCTAssertEqual(l.banned.first?.reason, "grief")
        XCTAssertTrue(l.whitelistOn)
    }

    func testMissingFilesAreEmptyNotAnError() {
        let d = makeTempDir()
        let l = AdminLists.read(serverDir: d.path)
        XCTAssertTrue(l.ops.isEmpty)
        XCTAssertTrue(l.whitelist.isEmpty)
        XCTAssertTrue(l.banned.isEmpty)
        XCTAssertFalse(l.whitelistOn)
    }
}
