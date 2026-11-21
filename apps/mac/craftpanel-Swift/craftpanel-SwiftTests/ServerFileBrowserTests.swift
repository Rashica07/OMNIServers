import XCTest
@testable import craftpanel_Swift

final class ServerFileBrowserTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func srv(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-files-\(tag)-\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: d.appending(path: "config"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: d.appending(path: "logs"), withIntermediateDirectories: true)
        try! "level-name=world\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        try! "verbose: false\n".write(to: d.appending(path: "config/paper.yml"), atomically: true, encoding: .utf8)
        try! "line1\nline2\nline3\n".write(to: d.appending(path: "logs/latest.log"), atomically: true, encoding: .utf8)
        tempDirs.append(d)
        return d
    }

    func testListsDirsFirstThenFiles() throws {
        let d = srv("ls")
        let l = try ServerFileBrowser.list(root: d, rel: "")
        XCTAssertEqual(l.path, "")
        XCTAssertNil(l.parent)
        XCTAssertTrue(l.entries[0].isDir) // config/ or logs/ before server.properties
        XCTAssertTrue(l.entries.contains { $0.name == "server.properties" && !$0.isDir })

        let sub = try ServerFileBrowser.list(root: d, rel: "config")
        XCTAssertEqual(sub.parent, "")
        XCTAssertTrue(sub.entries.contains { $0.name == "paper.yml" })
    }

    func testReadWriteRoundtripAndTraversalBlocked() throws {
        let d = srv("rw")
        let v = try ServerFileBrowser.read(root: d, rel: "config/paper.yml")
        XCTAssertTrue(v.text.contains("verbose"))
        try ServerFileBrowser.write(root: d, rel: "config/paper.yml", content: "verbose: true\n")
        XCTAssertEqual(try ServerFileBrowser.read(root: d, rel: "config/paper.yml").text, "verbose: true\n")

        XCTAssertThrowsError(try ServerFileBrowser.read(root: d, rel: "../../../etc/passwd"))
        XCTAssertThrowsError(try ServerFileBrowser.write(root: d, rel: "../escape.txt", content: "x"))
        XCTAssertThrowsError(try ServerFileBrowser.delete(root: d, rel: ".."))
    }

    func testDeleteMovesToTrashAndRenameWorks() throws {
        let d = srv("del")
        try ServerFileBrowser.delete(root: d, rel: "config/paper.yml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appending(path: "config/paper.yml").path))
        let trashed = try FileManager.default.contentsOfDirectory(at: d.appending(path: ".craftpanel-trash"), includingPropertiesForKeys: nil)
        XCTAssertEqual(trashed.count, 1)

        try ServerFileBrowser.write(root: d, rel: "notes.txt", content: "hi")
        try ServerFileBrowser.rename(root: d, from: "notes.txt", to: "docs/notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "docs/notes.txt").path))
    }

    func testTailReturnsLastLines() throws {
        let d = srv("tail")
        let t = try ServerFileBrowser.tail(root: d, rel: nil, maxLines: 2)
        XCTAssertEqual(t, "line2\nline3")
        XCTAssertThrowsError(try ServerFileBrowser.tail(root: d, rel: "logs/missing.log", maxLines: 10))
    }

    func testBinaryFilesFlaggedNotDumped() throws {
        let d = srv("bin")
        try Data([0, 1, 2, 0, 255]).write(to: d.appending(path: "world.dat"))
        let v = try ServerFileBrowser.read(root: d, rel: "world.dat")
        XCTAssertTrue(v.binary)
        XCTAssertTrue(v.text.isEmpty)
    }
}
