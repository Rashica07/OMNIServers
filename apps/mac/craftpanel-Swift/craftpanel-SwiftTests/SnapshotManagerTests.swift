import XCTest
@testable import craftpanel_Swift

final class SnapshotManagerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func server(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-snap-\(tag)-\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: d.appending(path: "world"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: d.appending(path: "mods"), withIntermediateDirectories: true)
        try! "level-name=world\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        try! Data("v1".utf8).write(to: d.appending(path: "world/level.dat"))
        try! Data("jar-bytes".utf8).write(to: d.appending(path: "mods/cool.jar"))
        tempDirs.append(d)
        return d
    }

    private func noop(_ s: String) {}

    func testASnapshotIsJustTheWorldNotTheWholeServer() throws {
        let d = server("first")
        let s = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)
        XCTAssertEqual(s.fileCount, 1)          // world/level.dat only
        XCTAssertTrue(s.isWorld)
        XCTAssertGreaterThan(s.newBytes, 0)
        XCTAssertEqual(SnapshotManager.list(dir: d).count, 1)
        let snap = d.appending(path: "craftpanel-snapshots/\(s.id)")
        let top = try FileManager.default.contentsOfDirectory(atPath: snap.path)
        XCTAssertEqual(top, ["world"], "no mods folder, jars or properties in a world snapshot")
    }

    func testNoWorldYetIsExplainedNotSnapshotted() throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-snap-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        try "level-name=world\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop))
        XCTAssertTrue(SnapshotManager.list(dir: d).isEmpty)
    }

    func testPaperStyleDimensionFoldersAndCustomLevelNamesAreIncluded() throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-snap-paper-\(UUID().uuidString)")
        let fm = FileManager.default
        tempDirs.append(d)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try "level-name=Survival\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        for f in ["Survival", "Survival_nether", "Survival_the_end", "world", "plugins"] {
            try fm.createDirectory(at: d.appending(path: f), withIntermediateDirectories: true)
            try Data(f.utf8).write(to: d.appending(path: "\(f)/level.dat"))
        }
        let s = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)
        XCTAssertEqual(s.fileCount, 3)   // not the other "world", not plugins
        try Data("ruined".utf8).write(to: d.appending(path: "Survival_nether/level.dat"))
        try SnapshotManager.restore(dir: d, id: s.id, progress: noop)
        XCTAssertEqual(try Data(contentsOf: d.appending(path: "Survival_nether/level.dat")), Data("Survival_nether".utf8))
        XCTAssertEqual(try Data(contentsOf: d.appending(path: "world/level.dat")), Data("world".utf8))
    }

    func testUnchangedFilesAreHardlinkedNotCopied() throws {
        let d = server("hardlink")
        let s1 = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)
        // nothing changed on disk at all
        let s2 = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)
        XCTAssertEqual(s2.newBytes, 0, "nothing changed, so nothing should be freshly copied")

        // and it's a *real* hard link, not just identical content
        let root = d.appending(path: "craftpanel-snapshots")
        let a = try FileManager.default.attributesOfItem(atPath: root.appending(path: "\(s1.id)/world/level.dat").path)
        let b = try FileManager.default.attributesOfItem(atPath: root.appending(path: "\(s2.id)/world/level.dat").path)
        XCTAssertEqual(a[.systemFileNumber] as? UInt64, b[.systemFileNumber] as? UInt64, "expected the same inode across snapshots")
    }

    func testChangedFileGetsAFreshCopyOthersStayLinked() throws {
        let d = server("changed")
        _ = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)
        try Data("v2-longer-than-before".utf8).write(to: d.appending(path: "world/level.dat"))
        let s2 = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)
        XCTAssertEqual(s2.newBytes, UInt64("v2-longer-than-before".utf8.count))
    }

    func testDeletingAnOlderSnapshotDoesNotCorruptANewerOneSharingHardlinks() throws {
        let d = server("delsafe")
        let s1 = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)
        let s2 = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop) // fully hardlinked to s1

        try SnapshotManager.delete(dir: d, id: s1.id)

        // s2's copy of the unchanged file must still read back correctly --
        // proves deleting s1 only dropped a link, not the underlying data
        let content = try Data(contentsOf: d.appending(path: "craftpanel-snapshots/\(s2.id)/world/level.dat"))
        XCTAssertEqual(content, Data("v1".utf8))
    }

    func testRestoreSwapsOnlyTheWorldAndKeepsTheOldOneAside() throws {
        let d = server("restore")
        let s1 = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)

        try Data("griefed".utf8).write(to: d.appending(path: "world/level.dat"))
        try Data("added later".utf8).write(to: d.appending(path: "newfile.txt"))
        try Data("new-mod".utf8).write(to: d.appending(path: "mods/other.jar"))
        try SnapshotManager.restore(dir: d, id: s1.id, progress: noop)

        XCTAssertEqual(try Data(contentsOf: d.appending(path: "world/level.dat")), Data("v1".utf8))
        // everything that isn't the world is left exactly as it was
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "newfile.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "mods/other.jar").path))

        let aside = try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(ServerFileCollector.preRestorePrefix) }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0].appending(path: "world/level.dat")), Data("griefed".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside[0].appending(path: "newfile.txt").path))

        // a world swap is undoable by itself; no whole-server zip is taken
        XCTAssertTrue(BackupManager.list(dir: d).isEmpty)
        XCTAssertEqual(SnapshotManager.list(dir: d).count, 1)
    }

    func testAFailedRestoreLeavesTheCurrentWorldAsItWas() throws {
        let d = server("failrestore")
        let fm = FileManager.default
        try Data(String(repeating: "b", count: 5000).utf8).write(to: d.appending(path: "world/big.bin"))
        let s1 = try SnapshotManager.snapshotNow(dir: d, trigger: "manual", progress: noop)
        try Data("CURRENT-STATE".utf8).write(to: d.appending(path: "world/level.dat"))
        let unreadable = d.appending(path: "craftpanel-snapshots/\(s1.id)/world/big.bin")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)   // the copy back fails part-way
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        XCTAssertThrowsError(try SnapshotManager.restore(dir: d, id: s1.id, progress: noop))
        XCTAssertEqual(try Data(contentsOf: d.appending(path: "world/level.dat")), Data("CURRENT-STATE".utf8))
        XCTAssertEqual(try Data(contentsOf: d.appending(path: "world/big.bin")).count, 5000)
        let aside = try fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(ServerFileCollector.preRestorePrefix) }
        XCTAssertTrue(aside.isEmpty, "nothing half-moved is left behind")
    }

    func testOlderWholeServerSnapshotsStillListAndRestoreTheWholeServer() throws {
        let d = server("legacy")
        let fm = FileManager.default
        // what the previous version made: a mirror of the whole folder, no "scope" in its JSON
        let id = "1700000000-abc123"
        let snap = d.appending(path: "craftpanel-snapshots/\(id)")
        for (url, rel) in ServerFileCollector.collect(dir: d) {
            let to = snap.appending(path: rel)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: to)
        }
        try JSONEncoder().encode(Snapshot(id: id, createdAt: 1_700_000_000, trigger: "manual", newBytes: 0, fileCount: 3))
            .write(to: d.appending(path: "craftpanel-snapshots/\(id).json"))
        let listed = SnapshotManager.list(dir: d)
        XCTAssertEqual(listed.count, 1)
        XCTAssertFalse(listed[0].isWorld)

        try Data("RUINED".utf8).write(to: d.appending(path: "world/level.dat"))
        try fm.removeItem(at: d.appending(path: "mods/cool.jar"))
        try SnapshotManager.restore(dir: d, id: id, progress: noop)
        XCTAssertEqual(try Data(contentsOf: d.appending(path: "world/level.dat")), Data("v1".utf8))
        XCTAssertTrue(fm.fileExists(atPath: d.appending(path: "mods/cool.jar").path), "the whole server went back")
        XCTAssertTrue(BackupManager.list(dir: d).contains { $0.trigger == "pre-restore" })
    }

    func testPruneKeepsRecentWindowAndThinsOlderToOnePerDay() throws {
        let d = server("prune")
        let root = d.appending(path: "craftpanel-snapshots")
        let now = Int64(Date().timeIntervalSince1970)

        func rewrite(_ s: Snapshot, createdAt: Int64) throws -> Snapshot {
            var m = s
            m.createdAt = createdAt
            try JSONEncoder().encode(m).write(to: root.appending(path: "\(m.id).json"))
            return m
        }

        // 3 snapshots today (well within a 24h recent window)
        var todayIDs: [String] = []
        for i in 0..<3 {
            let s = try SnapshotManager.snapshotNow(dir: d, trigger: "scheduled", progress: noop)
            let m = try rewrite(s, createdAt: now - Int64(i) * 60)
            todayIDs.append(m.id)
        }

        // 2 snapshots each on two older days (5 and 6 days ago) -- thin to 1/day.
        // Anchored to noon UTC on each target day so the pair never straddles
        // a UTC day boundary depending on when the test runs.
        let nowDayStart = (now / 86400) * 86400
        var olderKept: [String] = []
        for dayOffset: Int64 in [5, 6] {
            let dayNoon = nowDayStart - dayOffset * 86400 + 12 * 3600
            var best: String?
            for j in 0..<2 {
                let s = try SnapshotManager.snapshotNow(dir: d, trigger: "scheduled", progress: noop)
                let m = try rewrite(s, createdAt: dayNoon - Int64(j) * 3600)
                if j == 0 { best = m.id } // j=0 is the newer of the pair
            }
            olderKept.append(best!)
        }

        // 1 snapshot far outside the daily window (60 days ago) -- must be dropped entirely
        let ancient = try SnapshotManager.snapshotNow(dir: d, trigger: "scheduled", progress: noop)
        let ancientMeta = try rewrite(ancient, createdAt: now - 60 * 86400)

        SnapshotManager.prune(dir: d, keepRecentHours: 24, keepDailyDays: 30)
        let left = Set(SnapshotManager.list(dir: d).map(\.id))

        for id in todayIDs {
            XCTAssertTrue(left.contains(id), "recent snapshot \(id) should survive")
        }
        for id in olderKept {
            XCTAssertTrue(left.contains(id), "newest-of-the-day \(id) should survive thinning")
        }
        XCTAssertEqual(left.count, todayIDs.count + olderKept.count, "one-per-older-day, ancient one dropped")
        XCTAssertFalse(left.contains(ancientMeta.id), "60-day-old snapshot must be pruned outright")
    }
}
