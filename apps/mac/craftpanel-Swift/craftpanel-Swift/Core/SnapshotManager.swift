import Foundation

/// "Time Machine" world snapshots — cheap, frequent, hardlink-based
/// rollback points, stored under `<server>/craftpanel-snapshots/<id>/`.
/// Ported from `snapshots.rs`, then narrowed to the world.
///
/// A snapshot is the current state of the world save — the `level-name`
/// folder, Paper's `_nether`/`_the_end` folders, Bedrock's
/// `worlds/<name>` — not the jars, mods and configs that the zip
/// `BackupManager` copies; restoring swaps only the world. (Snapshots made
/// by earlier versions mirror the whole server folder and still restore
/// that way.) Files unchanged since the previous snapshot are hard-linked
/// (same inode, ~0 extra disk), only files that actually changed get a
/// fresh copy. `FileManager.linkItem`
/// is the exact Swift equivalent of Rust's `fs::hard_link`, so this
/// algorithm carries over essentially unchanged.
nonisolated struct Snapshot: Codable, Sendable, Identifiable {
    var id: String
    var createdAt: Int64
    /// "manual" | "scheduled"
    var trigger: String
    /// Bytes actually written fresh this snapshot (hard-linked files
    /// don't count) — the real marginal disk cost, not the tree's full
    /// logical size.
    var newBytes: UInt64
    var fileCount: UInt64
    /// "world" for a snapshot of just the world save; nil on older
    /// snapshots, which mirror the whole server folder.
    var scope: String?
    /// Explicitly protected by the user from automatic retention.
    var pinned: Bool = false

    var isWorld: Bool { scope == "world" }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt = "created_at", trigger, newBytes = "new_bytes", fileCount = "file_count", scope, pinned
    }

}

extension Snapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        trigger = try c.decode(String.self, forKey: .trigger)
        newBytes = try c.decode(UInt64.self, forKey: .newBytes)
        fileCount = try c.decode(UInt64.self, forKey: .fileCount)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

nonisolated enum SnapshotManager {
    private static func snapshotRoot(_ dir: URL) -> URL {
        dir.appending(path: ServerFileCollector.snapshotDirName)
    }

    /// A file is reused (hard-linked) instead of copied fresh only if its
    /// size *and* mtime match the previous snapshot's copy exactly — the
    /// same cheap "did this change" heuristic as the Rust source, without
    /// hashing contents (hashing every file on every snapshot would
    /// defeat the point of a cheap, frequent snapshot).
    private static func unchanged(_ cur: [FileAttributeKey: Any], _ prev: [FileAttributeKey: Any]) -> Bool {
        let curSize = (cur[.size] as? NSNumber)?.uint64Value
        let prevSize = (prev[.size] as? NSNumber)?.uint64Value
        let curMod = cur[.modificationDate] as? Date
        let prevMod = prev[.modificationDate] as? Date
        return curSize == prevSize && curMod == prevMod
    }

    // MARK: - What a snapshot covers

    /// The folders that make up the active world (relative to the server
    /// folder), only those that exist.
    static func worldFolders(dir: URL) -> [String] {
        var level = Properties.load(dir: dir).getOr("level-name", "world")
        if level.isEmpty || level.contains("/") || level.contains("\\") || level == "." || level == ".." { level = "world" }
        let fm = FileManager.default
        return [level, level + "_nether", level + "_the_end", "worlds/" + level].filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir.appending(path: $0).path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Every file of the active world, with paths relative to the server folder.
    static func collectWorld(dir: URL) -> [(url: URL, rel: String)] {
        var out: [(URL, String)] = []
        let fm = FileManager.default
        for root in worldFolders(dir: dir) {
            guard let en = fm.enumerator(at: dir.appending(path: root), includingPropertiesForKeys: [.isRegularFileKey], options: []) else { continue }
            for case let u as URL in en {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let rel = ServerFileCollector.relativePath(of: u, from: dir) else { continue }
                if rel.isEmpty || ServerFileCollector.excluded(rel) { continue }
                out.append((u, rel))
            }
        }
        return out
    }

    // MARK: - Create

    /// Take a snapshot: hard-link whatever didn't change since the
    /// previous snapshot, copy fresh whatever did (or everything, for
    /// the first one). `trigger` is "manual" or "scheduled".
    static func snapshotNow(dir: URL, trigger: String, progress: (String) -> Void) throws -> Snapshot {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw RconServiceError.message("Server folder is missing: \(dir.path)")
        }
        let root = snapshotRoot(dir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let latest = list(dir: dir).first
        let prevDir = latest.map { root.appending(path: $0.id) }

        // Strictly after the previous snapshot, so order is never ambiguous.
        let ts = max(Int64(Date().timeIntervalSince1970), (latest?.createdAt ?? 0) + 1)
        let id = "\(ts)-\(ServerFileCollector.shortID())"
        let newDir = root.appending(path: id)

        progress("Collecting the world…")
        let files = collectWorld(dir: dir)
        guard !files.isEmpty else {
            throw RconServiceError.message("There's no world to snapshot yet — start the server once so it creates one.")
        }
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        progress("Snapshotting \(files.count) files…")

        let fm = FileManager.default
        var newBytes: UInt64 = 0
        for (abs, rel) in files {
            let dest = newDir.appending(path: rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            var linked = false
            if let pd = prevDir {
                let prevFile = pd.appending(path: rel)
                if let curMeta = try? fm.attributesOfItem(atPath: abs.path),
                   let prevMeta = try? fm.attributesOfItem(atPath: prevFile.path),
                   unchanged(curMeta, prevMeta) {
                    linked = (try? fm.linkItem(at: prevFile, to: dest)) != nil
                }
            }
            if !linked {
                try fm.copyItem(at: abs, to: dest)
                let attrs = try? fm.attributesOfItem(atPath: abs.path)
                newBytes += (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            }
        }

        let meta = Snapshot(id: id, createdAt: ts, trigger: trigger, newBytes: newBytes, fileCount: UInt64(files.count), scope: "world", pinned: false)
        try writeSidecar(root: root, meta: meta)
        progress("Done.")
        return meta
    }

    private static func writeSidecar(root: URL, meta: Snapshot) throws {
        let data = try JSONEncoder().encode(meta)
        try data.write(to: root.appending(path: "\(meta.id).json"))
    }

    // MARK: - List / delete

    static func list(dir: URL) -> [Snapshot] {
        let root = snapshotRoot(dir)
        var out: [Snapshot] = []
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        for path in entries where path.pathExtension == "json" {
            guard let data = try? Data(contentsOf: path),
                  let meta = try? JSONDecoder().decode(Snapshot.self, from: data) else { continue }
            // a snapshot whose directory got deleted out from under us
            // (disk tampering, a crash mid-write) doesn't get listed as
            // if it were still restorable
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.appending(path: meta.id).path, isDirectory: &isDir), isDir.boolValue {
                out.append(meta)
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(dir: URL, id: String) throws {
        let id = try ServerFileCollector.sanitizeID(id)
        let root = snapshotRoot(dir)
        let target = root.appending(path: id)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            throw RconServiceError.message("That snapshot no longer exists.")
        }
        // safe regardless of hard-link fan-out: removing this directory's
        // links only drops each file's link count by one -- data backing
        // a file still linked from another snapshot is untouched.
        try FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: root.appending(path: "\(id).json"))
    }

    /// Tiered retention, Time-Machine style: every snapshot from the last
    /// `keepRecentHours` is kept outright; beyond that, thin to the
    /// newest snapshot per calendar day for up to `keepDailyDays` days;
    /// anything older is dropped. Bucketing is by UTC day.
    @discardableResult
    static func prune(dir: URL, keepRecentHours: Int, keepDailyDays: Int) -> [Retention.PruneFailure] {
        let all = list(dir: dir)
        guard !all.isEmpty else { return [] }
        let keepIDs = Retention.tieredKeepIDs(all.map { ($0.id, $0.createdAt) }, now: Int64(Date().timeIntervalSince1970),
                                              recentHours: keepRecentHours, dailyDays: keepDailyDays)
        let protected = Retention.protectedIDs(all.map { ($0.id, $0.createdAt, $0.pinned) })
        var failures: [Retention.PruneFailure] = []
        for s in all where !keepIDs.contains(s.id) {
            guard !protected.contains(s.id) else { continue }
            do { try delete(dir: dir, id: s.id) }
            catch { failures.append(.init(id: s.id, message: error.localizedDescription)) }
        }
        Retention.log(failures, kind: "snapshot")
        return failures
    }

    /// Euclidean floor division, matching Rust's `div_euclid` for
    /// negative-safe day bucketing (irrelevant pre-1970, but keeps the
    /// arithmetic identical to the source rather than assuming positive
    /// timestamps).
    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    // MARK: - Restore

    /// Restore a snapshot. Caller MUST ensure the server is stopped. A
    /// world snapshot swaps only the world: the current world folders are
    /// moved aside (never deleted, so it's undoable) and the snapshot is
    /// copied in; mods, configs and everything else stay. Older snapshots
    /// that mirror the whole server restore the whole server, after a zip
    /// safety-net backup. If anything fails, what was there is put back.
    static func restore(dir: URL, id: String, progress: (String) -> Void) throws {
        let id = try ServerFileCollector.sanitizeID(id)
        let src = snapshotRoot(dir).appending(path: id)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            throw RconServiceError.message("That snapshot no longer exists.")
        }
        if list(dir: dir).first(where: { $0.id == id })?.isWorld == true {
            try restoreWorld(dir: dir, src: src, progress: progress)
        } else {
            try restoreWholeServer(dir: dir, src: src, progress: progress)
        }
    }

    /// The world folders a world snapshot holds (world, world_nether, worlds/Name…).
    private static func snapshotWorldRoots(_ src: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for d in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
            if d.lastPathComponent == "worlds" {
                for w in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] { out.append("worlds/" + w.lastPathComponent) }
            } else {
                out.append(d.lastPathComponent)
            }
        }
        return out
    }

    private static func copySnapshotFiles(from src: URL, to dir: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw RconServiceError.message("Couldn't read the snapshot.")
        }
        for case let fileURL as URL in enumerator {
            guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else { continue }
            guard let rel = ServerFileCollector.relativePath(of: fileURL, from: src) else { continue }
            let out = dir.appending(path: rel)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            // a fresh copy, deliberately not another hard link -- restored
            // files should be independent of the snapshot store from here on.
            try? fm.removeItem(at: out)
            try fm.copyItem(at: fileURL, to: out)
        }
    }

    private static func restoreWorld(dir: URL, src: URL, progress: (String) -> Void) throws {
        let fm = FileManager.default
        let aside = dir.appending(path: "\(ServerFileCollector.preRestorePrefix)\(Int64(Date().timeIntervalSince1970))")
        let roots = snapshotWorldRoots(src)
        let existed = Set(roots.filter { fm.fileExists(atPath: dir.appending(path: $0).path) })
        var moved: [(from: URL, to: URL)] = []

        // Drop whatever the snapshot copy created, then return the folders
        // that were moved aside. A folder never moved is left alone.
        func rollback() {
            for r in roots where !existed.contains(r) { try? fm.removeItem(at: dir.appending(path: r)) }
            for m in moved {
                try? fm.removeItem(at: m.from)
                try? fm.moveItem(at: m.to, to: m.from)
            }
            let hasFiles = (fm.enumerator(at: aside, includingPropertiesForKeys: [.isRegularFileKey])?
                .contains { ((try? ($0 as? URL)?.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) == true }) ?? false
            if !hasFiles { try? fm.removeItem(at: aside) }
        }

        progress("Moving the current world aside…")
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        for rel in roots {
            let cur = dir.appending(path: rel)
            guard fm.fileExists(atPath: cur.path) else { continue }
            let to = aside.appending(path: rel)
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: cur, to: to)
                moved.append((cur, to))
            } catch {
                rollback()
                throw RconServiceError.message("couldn't move \(rel) aside: \(error.localizedDescription)")
            }
        }

        progress("Copying the snapshot back…")
        do {
            try copySnapshotFiles(from: src, to: dir)
        } catch {
            rollback()
            throw RconServiceError.message("\(error.localizedDescription) — your world was put back as it was.")
        }
        progress("Restored. The previous world is in \(aside.lastPathComponent)")
    }

    private static func restoreWholeServer(dir: URL, src: URL, progress: (String) -> Void) throws {
        progress("Backing up the current state first…")
        _ = try BackupManager.backupNow(dir: dir, label: "before restore", trigger: "pre-restore", progress: progress)

        progress("Moving the current folder aside…")
        let aside = dir.appending(path: "\(ServerFileCollector.preRestorePrefix)\(Int64(Date().timeIntervalSince1970))")
        let fm = FileManager.default
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                if name == ServerFileCollector.backupDirName || name == ServerFileCollector.snapshotDirName
                    || name.hasPrefix(ServerFileCollector.preRestorePrefix) {
                    continue
                }
                do {
                    try fm.moveItem(at: entry, to: aside.appending(path: name))
                } catch {
                    throw RconServiceError.message("couldn't move \(name) aside: \(error.localizedDescription)")
                }
            }
        }

        progress("Copying the snapshot back…")
        guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw RconServiceError.message("Couldn't read the snapshot.")
        }
        for case let fileURL as URL in enumerator {
            guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else { continue }
            guard let rel = ServerFileCollector.relativePath(of: fileURL, from: src) else { continue }
            let out = dir.appending(path: rel)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            // a fresh copy, deliberately not another hard link -- restored
            // files should be independent of the snapshot store from here on.
            try? fm.removeItem(at: out)
            try fm.copyItem(at: fileURL, to: out)
        }
        progress("Restored. The previous state is in \(aside.lastPathComponent)")
    }
}
