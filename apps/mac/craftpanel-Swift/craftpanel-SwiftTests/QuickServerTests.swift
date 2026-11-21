import XCTest
@testable import craftpanel_Swift

final class QuickServerTests: XCTestCase {
    private let versions = [VersionInfo(id: "26.1-pre2", kind: "snapshot"), VersionInfo(id: "1.21.8", kind: "release"), VersionInfo(id: "1.21.7", kind: "release")]

    func testPicksNewestRelease() {
        XCTAssertEqual(QuickServer.pickVersion(versions), "1.21.8")
        XCTAssertNil(QuickServer.pickVersion([VersionInfo(id: "x", kind: "snapshot")]))
    }

    func testRamFitsTheMac() {
        let tmp = FileManager.default.temporaryDirectory
        let big = QuickServer.plan(versions: versions, system: SystemMemory(totalMB: 32768, availableMB: 20000, memoryType: nil, chip: "", cores: 12), baseDir: tmp, usedNames: [])
        XCTAssertEqual(big?.ramMB, 3072)
        let small = QuickServer.plan(versions: versions, system: SystemMemory(totalMB: 4096, availableMB: 1500, memoryType: nil, chip: "", cores: 2), baseDir: tmp, usedNames: [])
        XCTAssertEqual(small?.ramMB, 2048)
    }

    func testNamesAndFoldersNeverClash() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "omni-qs-\(UUID().uuidString)")
        let busy = base.appending(path: "My-Server")
        try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try "x".write(to: busy.appending(path: "f"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(QuickServer.pickName(baseDir: base, usedNames: []).name, "My Server 2")
        XCTAssertEqual(QuickServer.pickName(baseDir: base, usedNames: ["My Server 2"]).name, "My Server 3")
        XCTAssertEqual(QuickServer.pickName(baseDir: base.appending(path: "other"), usedNames: []).name, "My Server")
    }
}
