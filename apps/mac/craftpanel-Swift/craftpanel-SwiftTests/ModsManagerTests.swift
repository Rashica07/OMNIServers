import XCTest
@testable import craftpanel_Swift

final class ModsManagerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func srv(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-mods-\(tag)-\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: d.appending(path: "mods"), withIntermediateDirectories: true)
        try! Data("jar1".utf8).write(to: d.appending(path: "mods/fabric-api-0.100.jar"))
        try! Data("jar2".utf8).write(to: d.appending(path: "mods/lithium-0.11.jar"))
        tempDirs.append(d)
        return d
    }

    func testUnsupportedLoaderReturnsWarningNotMods() {
        let d = srv("unsupported")
        let list = ModsManager.list(serverDir: d, serverType: .paper)
        XCTAssertFalse(list.supported)
        XCTAssertTrue(list.mods.isEmpty)
        XCTAssertFalse(list.warnings.isEmpty)
    }

    func testListsModsAndDetectsFabricAPI() {
        let d = srv("list")
        let list = ModsManager.list(serverDir: d, serverType: .fabric)
        XCTAssertTrue(list.supported)
        XCTAssertEqual(list.mods.count, 2)
        XCTAssertTrue(list.fabricAPIPresent)
        XCTAssertTrue(list.mods.allSatisfy(\.enabled))
    }

    func testWarnsWhenFabricAPIMissing() {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-mods-nofabric-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d.appending(path: "mods"), withIntermediateDirectories: true)
        try! Data("jar".utf8).write(to: d.appending(path: "mods/lithium-0.11.jar"))
        tempDirs.append(d)
        let list = ModsManager.list(serverDir: d, serverType: .fabric)
        XCTAssertFalse(list.fabricAPIPresent)
        XCTAssertTrue(list.warnings.contains { $0.contains("Fabric API") })
    }

    func testSetEnabledMovesBetweenFoldersAndRemoveTrashesIt() throws {
        let d = srv("toggle")
        try ModsManager.setEnabled(serverDir: d, name: "lithium-0.11.jar", enable: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appending(path: "mods/lithium-0.11.jar").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "mods-disabled/lithium-0.11.jar").path))

        let afterDisable = ModsManager.list(serverDir: d, serverType: .fabric)
        let lithium = afterDisable.mods.first { $0.name == "lithium-0.11.jar" }
        XCTAssertEqual(lithium?.enabled, false)

        try ModsManager.remove(serverDir: d, name: "lithium-0.11.jar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appending(path: "mods-disabled/lithium-0.11.jar").path))
        let trashed = try FileManager.default.contentsOfDirectory(at: d.appending(path: ".craftpanel-trash"), includingPropertiesForKeys: nil)
        XCTAssertEqual(trashed.count, 1)
    }

    func testRejectsUnsafeNames() {
        let d = srv("unsafe")
        XCTAssertThrowsError(try ModsManager.setEnabled(serverDir: d, name: "../evil.jar", enable: false))
        XCTAssertThrowsError(try ModsManager.remove(serverDir: d, name: "not-a-jar.txt"))
    }
}
