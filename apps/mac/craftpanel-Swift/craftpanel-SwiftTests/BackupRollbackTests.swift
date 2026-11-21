import XCTest
@testable import craftpanel_Swift

final class BackupRollbackTests: XCTestCase {
    func testFailedUnzipPutsOriginalFilesBack() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "cp-rollback-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appending(path: "world"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "level".write(to: dir.appending(path: "world/level.dat"), atomically: true, encoding: .utf8)
        try "motd=hi".write(to: dir.appending(path: "server.properties"), atomically: true, encoding: .utf8)

        let b = try BackupManager.backupNow(dir: dir, label: "t", trigger: "manual", progress: { _ in })
        // Corrupt the archive so extraction fails after everything was moved aside.
        try Data("definitely not a zip".utf8).write(to: BackupManager.backupRoot(dir).appending(path: "\(b.id).zip"))

        XCTAssertThrowsError(try BackupManager.restore(dir: dir, id: b.id, progress: { _ in }))
        XCTAssertEqual(try String(contentsOf: dir.appending(path: "world/level.dat"), encoding: .utf8), "level")
        XCTAssertEqual(try String(contentsOf: dir.appending(path: "server.properties"), encoding: .utf8), "motd=hi")
    }
}

final class VersionAndVerifyTests: XCTestCase {
    private func tempServer() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-cv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "jar".write(to: d.appending(path: "server.jar"), atomically: true, encoding: .utf8)
        return d
    }

    func testVerifyAndRecordFlagsGoodAndCorruptArchives() throws {
        let d = try tempServer(); defer { try? FileManager.default.removeItem(at: d) }
        let b = try BackupManager.backupNow(dir: d, label: nil, trigger: "manual") { _ in }
        XCTAssertTrue(try BackupManager.verifyAndRecord(dir: d, id: b.id))
        XCTAssertEqual(BackupManager.list(dir: d).first?.verified, true)
        try Data("junk".utf8).write(to: BackupManager.backupRoot(d).appending(path: "\(b.id).zip"))
        XCTAssertFalse(try BackupManager.verifyAndRecord(dir: d, id: b.id))
    }

    func testChangeVersionRefusesForgeAndLeavesJarAlone() async throws {
        let d = try tempServer(); defer { try? FileManager.default.removeItem(at: d) }
        do {
            _ = try await Provisioner.changeVersion(dir: d, oldLaunchTarget: "server.jar", name: "t", ramMB: 1024, javaPath: "java",
                                                    loader: .forge, mcVersion: "1.21.1", loaderVersion: nil) { _ in }
            XCTFail("expected refusal")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "server.jar").path))
    }
}
