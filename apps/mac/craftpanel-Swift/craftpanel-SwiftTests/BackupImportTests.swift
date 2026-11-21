import XCTest
@testable import craftpanel_Swift

/// A backup made on someone else's Mac (their .zip and .json) added to this Mac's server, then restored.
final class BackupImportTests: XCTestCase {
    private var tempDirs: [URL] = []
    private let fm = FileManager.default

    override func tearDown() {
        for d in tempDirs { try? fm.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tmp(_ tag: String) -> URL {
        let d = fm.temporaryDirectory.appending(path: "cp-imp-\(tag)-\(UUID().uuidString)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    private func server(_ tag: String, levelDat: String, mod: String) -> URL {
        let d = tmp(tag)
        try! fm.createDirectory(at: d.appending(path: "world"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: d.appending(path: "mods"), withIntermediateDirectories: true)
        try! "level-name=world\nmotd=\(tag)\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        try! Data(levelDat.utf8).write(to: d.appending(path: "world/level.dat"))
        try! Data("MOD:\(mod)".utf8).write(to: d.appending(path: "mods/\(mod)"))
        return d
    }

    private func noop(_ s: String) {}

    /// Their latest backup, copied to a "USB stick" folder the way a friend would send it.
    private func friendsBackup(label: String = "friday night") throws -> (zip: URL, json: URL, meta: Backup) {
        let friend = server("friend", levelDat: "FRIENDS-LATEST-WORLD", mod: "fabric-api.jar")
        let meta = try BackupManager.backupNow(dir: friend, label: label, trigger: "manual", progress: noop)
        let stick = tmp("stick")
        let root = BackupManager.backupRoot(friend)
        try fm.copyItem(at: root.appending(path: "\(meta.id).zip"), to: stick.appending(path: "\(meta.id).zip"))
        try fm.copyItem(at: root.appending(path: "\(meta.id).json"), to: stick.appending(path: "\(meta.id).json"))
        return (stick.appending(path: "\(meta.id).zip"), stick.appending(path: "\(meta.id).json"), meta)
    }

    /// A zip with exactly these entry names (zip's own command line refuses "../", so python writes it).
    private func makeZip(_ name: String, _ entries: [(String, String)]) throws -> URL {
        let path = tmp("zip").appending(path: name)
        let script = "import sys,zipfile\nz=zipfile.ZipFile(sys.argv[1],'w')\nfor i in range(2,len(sys.argv),2): z.writestr(sys.argv[i],sys.argv[i+1])\nz.close()"
        var args = ["-c", script, path.path]
        for (n, t) in entries { args += [n, t] }
        let r = try Subprocess.run("/usr/bin/python3", args, timeout: 60)
        XCTAssertEqual(r.status, 0, r.stderrString)
        return path
    }

    func testAFriendsLatestBackupImportsAndRestoresOntoMyOlderServer() throws {
        let (zip, json, theirs) = try friendsBackup()
        let mine = server("mine", levelDat: "MY-OLDER-WORLD", mod: "my-old-mod.jar")
        _ = try BackupManager.backupNow(dir: mine, label: "mine", trigger: "manual", progress: noop)

        let imported = try BackupManager.importBackup(dir: mine, zip: zip, json: json, progress: noop)
        XCTAssertEqual(imported.trigger, "imported")
        XCTAssertEqual(imported.label, "friday night")          // their label and their time are kept
        XCTAssertEqual(imported.createdAt, theirs.createdAt)
        XCTAssertEqual(imported.verified, true)
        XCTAssertEqual(BackupManager.list(dir: mine).count, 2)

        try BackupManager.restore(dir: mine, id: imported.id, progress: noop)
        XCTAssertEqual(try Data(contentsOf: mine.appending(path: "world/level.dat")), Data("FRIENDS-LATEST-WORLD".utf8))
        XCTAssertTrue(fm.fileExists(atPath: mine.appending(path: "mods/fabric-api.jar").path))
        XCTAssertTrue(BackupManager.list(dir: mine).contains { $0.trigger == "pre-restore" }, "what I had was backed up first")
    }

    func testTheJSONIsFoundNextToTheZipAndIsOptional() throws {
        let (zip, _, theirs) = try friendsBackup()
        let mine = server("mine", levelDat: "X", mod: "a.jar")
        XCTAssertEqual(BackupManager.siblingJSON(of: zip)?.lastPathComponent, "\(theirs.id).json")
        XCTAssertEqual(try BackupManager.importBackup(dir: mine, zip: zip, json: BackupManager.siblingJSON(of: zip), progress: noop).createdAt, theirs.createdAt)

        let mine2 = server("mine2", levelDat: "X", mod: "a.jar")      // the zip alone: dated by the file
        let when = Date(timeIntervalSince1970: 1_772_625_600)
        try fm.setAttributes([.modificationDate: when], ofItemAtPath: zip.path)
        let b = try BackupManager.importBackup(dir: mine2, zip: zip, json: nil, progress: noop)
        XCTAssertEqual(b.createdAt, 1_772_625_600)
        XCTAssertNil(b.label)
    }

    func testADamagedOrStrangeJSONIsIgnoredNotTrusted() throws {
        let (zip, json, _) = try friendsBackup()
        let mine = server("mine", levelDat: "X", mod: "a.jar")
        try "{ this is not json".write(to: json, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try BackupManager.importBackup(dir: mine, zip: zip, json: json, progress: noop))

        let mine2 = server("mine2", levelDat: "X", mod: "a.jar")
        let odd = #"{"id":"../../evil","created_at":4000000000,"size_bytes":1,"label":"bad\u0007label","trigger":"pre-restore"}"#
        try odd.write(to: json, atomically: true, encoding: .utf8)
        let b = try BackupManager.importBackup(dir: mine2, zip: zip, json: json, progress: noop)
        XCTAssertFalse(b.id.contains(".."), "ids are always made here")
        XCTAssertLessThan(b.createdAt, Int64(Date().timeIntervalSince1970) + 100_000, "a far-future time is not believed")
        XCTAssertEqual(b.trigger, "imported")
        XCTAssertFalse((b.label ?? "").contains("\u{07}"))
        XCTAssertGreaterThan(b.sizeBytes, 1, "the real size, not the claimed one")
    }

    func testImportingTheSameFileTwiceIsRefused() throws {
        let (zip, json, _) = try friendsBackup()
        let mine = server("mine", levelDat: "X", mod: "a.jar")
        _ = try BackupManager.importBackup(dir: mine, zip: zip, json: json, progress: noop)
        XCTAssertThrowsError(try BackupManager.importBackup(dir: mine, zip: zip, json: json, progress: noop)) {
            XCTAssertTrue($0.localizedDescription.contains("already imported"))
        }
        XCTAssertEqual(BackupManager.list(dir: mine).count, 1)
    }

    func testZipsThatReachOutsideTheServerFolderAreRefused() throws {
        for entry in ["../evil.txt", "world/../../evil.txt", "/etc/passwd", "C:/Windows/evil.dll",
                      "craftpanel-backups/planted.zip", "craftpanel-snapshots/x/world/level.dat", ".craftpanel-pre-restore-1/world/level.dat"] {
            let zip = try makeZip("evil.zip", [("server.properties", "a=b"), (entry, "x")])
            let mine = server("mine", levelDat: "X", mod: "a.jar")
            XCTAssertThrowsError(try BackupManager.importBackup(dir: mine, zip: zip, json: nil, progress: noop), entry) {
                XCTAssertTrue($0.localizedDescription.contains("outside the server folder"), entry)
            }
            XCTAssertTrue(BackupManager.list(dir: mine).isEmpty, entry)
            let leftovers = (try? fm.contentsOfDirectory(atPath: BackupManager.backupRoot(mine).path)) ?? []
            XCTAssertTrue(leftovers.isEmpty, "nothing was copied in for \(entry)")
        }
    }

    func testFilesThatAreNotServerBackupsAreRefusedWithAReason() throws {
        let mine = server("mine", levelDat: "X", mod: "a.jar")
        let notZip = tmp("nz").appending(path: "notes.zip")
        try "plain text pretending".write(to: notZip, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BackupManager.importBackup(dir: mine, zip: notZip, json: nil, progress: noop)) {
            XCTAssertTrue($0.localizedDescription.contains("valid .zip"))
        }
        let photos = try makeZip("photos.zip", [("holiday/img1.jpg", "x"), ("readme.txt", "hi")])
        XCTAssertThrowsError(try BackupManager.importBackup(dir: mine, zip: photos, json: nil, progress: noop)) {
            XCTAssertTrue($0.localizedDescription.contains("doesn't look like a Minecraft server"))
        }
        XCTAssertThrowsError(try BackupManager.importBackup(dir: mine, zip: mine.appending(path: "missing.zip"), json: nil, progress: noop))
        XCTAssertTrue(BackupManager.list(dir: mine).isEmpty)
    }

    func testAnImportedBackupSurvivesTheAutomaticCleanup() throws {
        let (zip, json, _) = try friendsBackup()
        let mine = server("mine", levelDat: "X", mod: "a.jar")
        let imported = try BackupManager.importBackup(dir: mine, zip: zip, json: json, progress: noop)
        for _ in 0..<3 { _ = try BackupManager.backupNow(dir: mine, label: nil, trigger: "manual", progress: noop); Thread.sleep(forTimeInterval: 1.1) }
        BackupManager.prune(dir: mine, keep: 1)
        XCTAssertTrue(BackupManager.list(dir: mine).contains { $0.id == imported.id }, "keep-newest-1 must not eat the friend's backup")
        // Automatic cleanup keeps the imported recovery point plus both
        // endpoints of the native recovery history.
        XCTAssertEqual(BackupManager.list(dir: mine).count, 3)
        BackupManager.pruneTiered(dir: mine, recentHours: 1, dailyDays: 1, now: Int64(Date().timeIntervalSince1970) + 90 * 86400)
        XCTAssertTrue(BackupManager.list(dir: mine).contains { $0.id == imported.id })
    }

    func testInspectionReportsWhatIsInsideBeforeAnythingIsCopied() throws {
        let (zip, _, _) = try friendsBackup()
        let info = try BackupManager.inspectZip(zip)
        XCTAssertTrue(info.hasWorld); XCTAssertTrue(info.hasServerProperties)
        XCTAssertEqual(info.mods, 1); XCTAssertNil(info.unsafeEntry); XCTAssertTrue(info.looksLikeAServer)
        XCTAssertGreaterThan(info.uncompressedBytes, 0)
    }
}
