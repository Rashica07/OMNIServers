import XCTest
@testable import craftpanel_Swift

final class BackupManagerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func server(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-bak-\(tag)-\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: d.appending(path: "world"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: d.appending(path: "logs"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: d.appending(path: "mods"), withIntermediateDirectories: true)
        try! "level-name=world\nonline-mode=false\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        try! Data("v1".utf8).write(to: d.appending(path: "world/level.dat"))
        try! Data("jar".utf8).write(to: d.appending(path: "mods/cool.jar"))
        try! Data("noise".utf8).write(to: d.appending(path: "logs/latest.log"))
        tempDirs.append(d)
        return d
    }

    private func noop(_ s: String) {}

    func testBackupExcludesLogsKeepsModsAndLists() throws {
        let d = server("mk")
        let b = try BackupManager.backupNow(dir: d, label: "first", trigger: "manual", progress: noop)
        XCTAssertGreaterThan(b.sizeBytes, 0)
        XCTAssertEqual(b.label, "first")

        let listed = BackupManager.list(dir: d)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, b.id)

        // peek inside via /usr/bin/unzip -l
        let names = try zipEntryNames(d.appending(path: "craftpanel-backups/\(b.id).zip"))
        XCTAssertTrue(names.contains("world/level.dat"))
        XCTAssertTrue(names.contains("mods/cool.jar"))
        XCTAssertFalse(names.contains { $0.hasPrefix("logs/") })
        XCTAssertFalse(names.contains { $0.hasPrefix("craftpanel-backups") })
    }

    func testRestoreRollsBackWorldAndKeepsPreviousState() throws {
        let d = server("restore")
        let b = try BackupManager.backupNow(dir: d, label: nil, trigger: "manual", progress: noop)

        try Data("v2-griefed".utf8).write(to: d.appending(path: "world/level.dat"))
        try Data("added later".utf8).write(to: d.appending(path: "newfile.txt"))
        try BackupManager.restore(dir: d, id: b.id, progress: noop)

        XCTAssertEqual(try Data(contentsOf: d.appending(path: "world/level.dat")), Data("v1".utf8))

        let aside = try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(ServerFileCollector.preRestorePrefix) }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0].appending(path: "world/level.dat")), Data("v2-griefed".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside[0].appending(path: "newfile.txt").path))

        XCTAssertTrue(BackupManager.list(dir: d).contains { $0.trigger == "pre-restore" })
    }

    func testPruneKeepsNewestAndSparesPreRestore() throws {
        let d = server("prune")
        var ids: [String] = []
        for i in 0..<5 {
            let b = try BackupManager.backupNow(dir: d, label: "b\(i)", trigger: "manual", progress: noop)
            ids.append(b.id)
            // force distinct createdAt ordering, same as the Rust test
            var meta = b
            meta.createdAt = 1000 + Int64(i)
            try JSONEncoder().encode(meta).write(to: d.appending(path: "craftpanel-backups/\(b.id).json"))
        }
        let pr = try BackupManager.backupNow(dir: d, label: nil, trigger: "pre-restore", progress: noop)

        BackupManager.prune(dir: d, keep: 2)
        let left = BackupManager.list(dir: d)
        let manualLeft = left.filter { $0.trigger == "manual" }.count
        XCTAssertEqual(manualLeft, 2)
        XCTAssertTrue(left.contains { $0.id == pr.id }, "pre-restore must be kept")
    }

    private func zipEntryNames(_ zip: URL) throws -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
