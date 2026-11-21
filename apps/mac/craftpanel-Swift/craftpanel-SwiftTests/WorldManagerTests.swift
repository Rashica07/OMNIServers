import XCTest
@testable import craftpanel_Swift

final class WorldManagerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func srv(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-worlds-\(tag)-\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: d.appending(path: "world"), withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: d.appending(path: "world/level.dat"))
        try! fm.createDirectory(at: d.appending(path: "world_nether"), withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: d.appending(path: "world_nether/level.dat"))
        try! fm.createDirectory(at: d.appending(path: "old-smp"), withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: d.appending(path: "old-smp/level.dat"))
        try! "level-name=world\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        tempDirs.append(d)
        return d
    }

    func testListsWorldsAndMarksActive() {
        let d = srv("list")
        let info = WorldManager.list(serverDir: d)
        XCTAssertEqual(info.active, "world")
        let w = info.worlds.first { $0.name == "world" }!
        XCTAssertTrue(w.active)
        XCTAssertTrue(w.hasNether)
        XCTAssertFalse(w.hasEnd)
        XCTAssertTrue(info.worlds.contains { $0.name == "old-smp" && !$0.active })
        // nether/end folders aren't listed as their own worlds
        XCTAssertFalse(info.worlds.contains { $0.name == "world_nether" })
    }

    func testSwitchRenameDelete() throws {
        let d = srv("ops")

        try WorldManager.setActive(serverDir: d, name: "old-smp")
        XCTAssertEqual(Properties.load(dir: d).getOr("level-name", ""), "old-smp")

        // now "world" is inactive -> renamable + deletable
        try WorldManager.rename(serverDir: d, from: "world", to: "backup-world")
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "backup-world/level.dat").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "backup-world_nether/level.dat").path))

        try WorldManager.delete(serverDir: d, name: "backup-world")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appending(path: "backup-world").path))
        let trashed = try FileManager.default.contentsOfDirectory(at: d.appending(path: ".craftpanel-trash"), includingPropertiesForKeys: nil)
        XCTAssertGreaterThanOrEqual(trashed.count, 1)

        // can't delete the active world
        XCTAssertThrowsError(try WorldManager.delete(serverDir: d, name: "old-smp"))
    }

    func testCreatePointsLevelNameAndSeed() throws {
        let d = srv("create")
        try WorldManager.create(serverDir: d, name: "hardcore", seed: "12345")
        let p = Properties.load(dir: d)
        XCTAssertEqual(p.getOr("level-name", ""), "hardcore")
        XCTAssertEqual(p.getOr("level-seed", ""), "12345")
    }

    func testRejectsBadNames() {
        let d = srv("evil")
        XCTAssertThrowsError(try WorldManager.setActive(serverDir: d, name: "../etc"))
        XCTAssertThrowsError(try WorldManager.rename(serverDir: d, from: "world", to: "a/b"))
        XCTAssertThrowsError(try WorldManager.create(serverDir: d, name: "", seed: nil))
    }

    func testImportsFolderWithoutMovingSourceAndExportsZip() throws {
        let server = srv("import")
        let source = FileManager.default.temporaryDirectory.appending(path: "cp-single-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source.appending(path: "My Save"), withIntermediateDirectories: true)
        try Data("level".utf8).write(to: source.appending(path: "My Save/level.dat"))
        try Data("region".utf8).write(to: source.appending(path: "My Save/region.mca"))
        tempDirs.append(source)

        let imported = try WorldManager.importWorld(from: source, serverDir: server)
        XCTAssertEqual(imported, "My Save")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appending(path: "My Save/level.dat").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.appending(path: "My Save/region.mca").path))

        let archive = FileManager.default.temporaryDirectory.appending(path: "cp-export-(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try WorldManager.exportWorld(serverDir: server, name: imported, to: archive)
        let listing = try Subprocess.run("/usr/bin/zipinfo", ["-1", archive.path], timeout: 30)
        XCTAssertEqual(listing.status, 0)
        XCTAssertTrue(listing.stdoutString.contains("My Save/level.dat"))
    }

    func testImportsZippedVanillaWorld() throws {
        let server = srv("zip-import")
        let source = FileManager.default.temporaryDirectory.appending(path: "cp-zip-source-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source.appending(path: "Vanilla/region"), withIntermediateDirectories: true)
        try Data("level".utf8).write(to: source.appending(path: "Vanilla/level.dat"))
        try Data("chunk".utf8).write(to: source.appending(path: "Vanilla/region/r.0.0.mca"))
        tempDirs.append(source)
        let archive = FileManager.default.temporaryDirectory.appending(path: "cp-zip-world-(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        let zipped = try Subprocess.run("/usr/bin/zip", ["-q", "-r", archive.path, "Vanilla"], cwd: source, timeout: 30)
        XCTAssertEqual(zipped.status, 0)

        let name = try WorldManager.importWorld(from: archive, serverDir: server)
        XCTAssertEqual(name, "Vanilla")
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.appending(path: "Vanilla/region/r.0.0.mca").path))
    }

    func testImportRejectsRunningActivationAndNonWorld() throws {
        let server = srv("reject")
        XCTAssertThrowsError(try WorldManager.importWorld(from: server.appending(path: "not-a-world"), serverDir: server))
        XCTAssertThrowsError(try WorldManager.importWorld(from: server.appending(path: "world"), serverDir: server, activate: true, serverRunning: true))
    }
}
