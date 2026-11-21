import Foundation
import CryptoKit

/// Server backups — a zip of the whole server folder minus regenerable
/// junk, stored under `<server>/craftpanel-backups/`. Direct port of
/// `backups.rs`.
///
/// Restore never deletes: the current folder contents are moved aside to
/// `.craftpanel-pre-restore-<ts>/` and a fresh `pre-restore` backup is
/// taken first, so a restore is always reversible.
///
/// Zipping via `/usr/bin/zip`/`unzip` rather than a vendored zip library
/// — matches the plan's own "no shell involved, arguments as an array"
/// rule already used for `MinecraftAdapter.startCommand`. One
/// simplification versus the Rust source: this doesn't distinguish
/// stored-vs-deflated compression per file (jars/images stored
/// uncompressed, everything else deflated at a fast level) — `zip`'s CLI
/// doesn't expose that per-invocation without one process per file, which
/// would be far slower than the CPU it's meant to save. Correctness is
/// unaffected; only the marginal CPU-during-backup cost changes.
nonisolated struct Backup: Codable, Sendable, Identifiable {
    var id: String
    var createdAt: Int64
    var sizeBytes: UInt64
    var label: String?
    /// "manual" | "pre-restore" | "scheduled"
    var trigger: String
    /// Result of the last integrity check (nil = never checked).
    var verified: Bool?
    /// SHA-256 of the zip as it was when imported from elsewhere, so the
    /// same file can't be imported twice. nil on backups made here.
    var sourceSha256: String?
    /// Explicitly protected by the user from automatic retention.
    var pinned: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, createdAt = "created_at", sizeBytes = "size_bytes", label, trigger, verified
        case sourceSha256 = "source_sha256", pinned
    }

}

extension Backup {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        sizeBytes = try c.decode(UInt64.self, forKey: .sizeBytes)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        trigger = try c.decode(String.self, forKey: .trigger)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified)
        sourceSha256 = try c.decodeIfPresent(String.self, forKey: .sourceSha256)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

nonisolated enum BackupManager {
    static func backupRoot(_ dir: URL) -> URL {
        dir.appending(path: ServerFileCollector.backupDirName)
    }

    // MARK: - Create

    /// Zip the server folder and record a sidecar. `trigger` is one of
    /// `manual` / `pre-restore` / `scheduled`.
    static func backupNow(dir: URL, label: String?, trigger: String, progress: (String) -> Void) throws -> Backup {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw RconServiceError.message("Server folder is missing: \(dir.path)")
        }
        let root = backupRoot(dir)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let ts = Int64(Date().timeIntervalSince1970)
        let id = "\(ts)-\(ServerFileCollector.shortID())"

        progress("Collecting files…")
        let files = ServerFileCollector.collect(dir: dir)
        progress("Compressing \(files.count) files…")

        let zipPath = root.appending(path: "\(id).zip")
        try runZip(sourceDir: dir, relativePaths: files.map(\.rel), destination: zipPath)

        let attrs = try? FileManager.default.attributesOfItem(atPath: zipPath.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

        let meta = Backup(
            id: id, createdAt: ts, sizeBytes: size,
            label: label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
            trigger: trigger, pinned: false
        )
        try writeSidecar(root: root, meta: meta)
        progress("Done.")
        return meta
    }

    /// Runs `/usr/bin/zip` with a stdin-piped file list (never a shell,
    /// never string-interpolated paths into a command line) and the
    /// working directory set to the server folder, so entries land at
    /// the same relative paths Rust's zip writer used.
    private static func runZip(sourceDir: URL, relativePaths: [String], destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        guard !relativePaths.isEmpty else {
            // `zip` errors on an empty file list; write a valid empty
            // archive by hand instead (a server with nothing backupable
            // yet is a real, if unusual, state).
            let emptyZip = Data([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            try emptyZip.write(to: destination)
            return
        }
        let list = Data((relativePaths.joined(separator: "\n") + "\n").utf8)
        let r = try Subprocess.run("/usr/bin/zip", ["-q", destination.path, "-@"], cwd: sourceDir, stdin: list)
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: destination) // no half-written archive left behind
            let errText = r.stderrString
            throw RconServiceError.message("zip failed: \(errText.isEmpty ? "exit \(r.status)" : errText)")
        }
    }

    private static func writeSidecar(root: URL, meta: Backup) throws {
        let data = try JSONEncoder().encode(meta)
        try data.write(to: root.appending(path: "\(meta.id).json"))
    }

    // MARK: - Import (a backup made somewhere else: another Mac, another person)

    /// What's inside a zip, found out before anything is copied.
    struct ZipInspection: Sendable {
        var entries = 0
        var uncompressedBytes: UInt64 = 0
        var hasServerProperties = false
        var hasWorld = false
        var mods = 0
        var plugins = 0
        var unsafeEntry: String?
        var looksLikeAServer: Bool { hasServerProperties || hasWorld || mods > 0 || plugins > 0 }
    }

    /// An entry name that could write outside the server folder, or into
    /// OMNIServers's own folders.
    static func isUnsafeEntry(_ name: String) -> Bool {
        let n = name.replacingOccurrences(of: "\\", with: "/")
        if n.hasPrefix("/") || n.contains(":") || n.contains("\0") { return true }
        let segs = n.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segs.contains("..") { return true }
        let first = (segs.first ?? "").lowercased()
        return first == ServerFileCollector.backupDirName || first == ServerFileCollector.snapshotDirName
            || first.hasPrefix(ServerFileCollector.preRestorePrefix)
    }

    static func inspectZip(_ zip: URL) throws -> ZipInspection {
        guard let r = try? Subprocess.run("/usr/bin/zipinfo", ["-1", zip.path], timeout: 120), r.status == 0 else {
            throw RconServiceError.message("That file isn't a valid .zip backup.")
        }
        var info = ZipInspection()
        for line in r.stdoutString.split(separator: "\n", omittingEmptySubsequences: true) {
            let name = String(line)
            info.entries += 1
            if isUnsafeEntry(name), info.unsafeEntry == nil { info.unsafeEntry = name }
            let n = name.lowercased()
            if n == "server.properties" { info.hasServerProperties = true }
            if n.hasSuffix("/level.dat") || n == "level.dat" || n.hasPrefix("world/") || n.hasPrefix("worlds/") { info.hasWorld = true }
            if n.hasPrefix("mods/") && n.hasSuffix(".jar") { info.mods += 1 }
            if n.hasPrefix("plugins/") && n.hasSuffix(".jar") { info.plugins += 1 }
        }
        // total unpacked size, from the summary line: "N files, X bytes uncompressed, ..."
        if let t = try? Subprocess.run("/usr/bin/zipinfo", ["-t", zip.path], timeout: 120),
           let range = t.stdoutString.range(of: #"(\d+) bytes uncompressed"#, options: .regularExpression) {
            info.uncompressedBytes = UInt64(t.stdoutString[range].split(separator: " ").first ?? "") ?? 0
        }
        return info
    }

    /// The .json that goes with a zip, if it sits next to it under the same name.
    static func siblingJSON(of zip: URL) -> URL? {
        let j = zip.deletingPathExtension().appendingPathExtension("json")
        return FileManager.default.fileExists(atPath: j.path) ? j : nil
    }

    private static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Adds a backup made elsewhere (its .zip, and its .json if there is one)
    /// to this server's list: checked for unsafe paths and for being a real
    /// archive, copied in under a fresh id, listed as "imported". Nothing
    /// about the server changes until you restore it. The same file twice
    /// is refused.
    @discardableResult
    static func importBackup(dir: URL, zip: URL, json: URL?, progress: (String) -> Void) throws -> Backup {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw RconServiceError.message("Server folder is missing: \(dir.path)")
        }
        guard fm.fileExists(atPath: zip.path) else { throw RconServiceError.message("That backup file doesn't exist.") }
        progress("Checking the backup…")
        let info = try inspectZip(zip)
        if let bad = info.unsafeEntry {
            throw RconServiceError.message("This backup contains a file that would land outside the server folder (\(bad)), so OMNIServers won't import it.")
        }
        guard info.entries > 0, info.looksLikeAServer else {
            throw RconServiceError.message("That zip doesn't look like a Minecraft server backup (no server.properties, world, mods or plugins in it).")
        }
        let hash = try sha256(of: zip)
        if let dup = list(dir: dir).first(where: { $0.sourceSha256 == hash }) {
            throw RconServiceError.message("You've already imported this backup (\(Date(timeIntervalSince1970: TimeInterval(dup.createdAt)).formatted(date: .abbreviated, time: .shortened))).")
        }
        let size = (try fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let root = backupRoot(dir)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           UInt64(max(free, 0)) < size + (256 << 20) {
            throw RconServiceError.message("Not enough free disk space to import this backup (\(size / 1_048_576) MB needed).")
        }

        // Their .json is only a hint: a missing, damaged or odd one is ignored, and only the label and time are used.
        var side: Backup?
        if let json, (try? fm.attributesOfItem(atPath: json.path)[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1024 {
            side = (try? Data(contentsOf: json)).flatMap { try? JSONDecoder().decode(Backup.self, from: $0) }
        }
        let now = Int64(Date().timeIntervalSince1970)
        let fileDate = ((try? fm.attributesOfItem(atPath: zip.path)[.modificationDate]) as? Date).map { Int64($0.timeIntervalSince1970) } ?? now
        let created = (side.map { $0.createdAt > 946_684_800 && $0.createdAt <= now + 86400 } ?? false) ? side!.createdAt : fileDate
        let id = "\(created)-\(ServerFileCollector.shortID())"
        let dest = root.appending(path: "\(id).zip")
        progress("Copying it in…")
        do { try fm.copyItem(at: zip, to: dest) } catch { try? fm.removeItem(at: dest); throw error }

        let label = side?.label.map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80)) }
        let meta = Backup(id: id, createdAt: created, sizeBytes: size,
                          label: (label?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? nil : label,
                          trigger: "imported", verified: nil, sourceSha256: hash, pinned: side?.pinned ?? false)
        try writeSidecar(root: root, meta: meta)
        progress("Checking it's not damaged…")
        try? verifyAndRecord(dir: dir, id: id)
        progress("Done.")
        return list(dir: dir).first { $0.id == id } ?? meta
    }

    // MARK: - List / delete

    static func list(dir: URL) -> [Backup] {
        let root = backupRoot(dir)
        var out: [Backup] = []
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        for path in entries where path.pathExtension == "json" {
            guard let data = try? Data(contentsOf: path),
                  var meta = try? JSONDecoder().decode(Backup.self, from: data) else { continue }
            // trust the zip on disk for the real size
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: root.appending(path: "\(meta.id).zip").path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            meta.sizeBytes = size
            out.append(meta)
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(dir: URL, id: String) throws {
        let id = try ServerFileCollector.sanitizeID(id)
        let root = backupRoot(dir)
        let zip = root.appending(path: "\(id).zip")
        guard FileManager.default.fileExists(atPath: zip.path) else {
            throw RconServiceError.message("That backup no longer exists.")
        }
        try FileManager.default.removeItem(at: zip)
        try? FileManager.default.removeItem(at: root.appending(path: "\(id).json"))
    }

    /// Keep the newest `keep` manual/scheduled backups, delete the rest.
    /// `pre-restore` and `imported` backups are left alone. `keep == 0` means unlimited.
    @discardableResult
    static func prune(dir: URL, keep: Int) -> [Retention.PruneFailure] {
        guard keep > 0 else { return [] }
        let prunable = list(dir: dir).filter { $0.trigger != "pre-restore" && $0.trigger != "imported" }
        let protected = Retention.protectedIDs(prunable.map { ($0.id, $0.createdAt, $0.pinned) })
        var failures: [Retention.PruneFailure] = []
        for old in prunable.dropFirst(keep) where !protected.contains(old.id) {
            do { try delete(dir: dir, id: old.id) }
            catch { failures.append(.init(id: old.id, message: error.localizedDescription)) }
        }
        Retention.log(failures, kind: "backup")
        return failures
    }

    /// Test-extract the archive (`unzip -tq`) and record the result in the
    /// sidecar — port of `verify_and_record`.
    @discardableResult
    static func verifyAndRecord(dir: URL, id: String) throws -> Bool {
        let id = try ServerFileCollector.sanitizeID(id)
        let root = backupRoot(dir)
        let ok = ((try? Subprocess.run("/usr/bin/unzip", ["-tq", root.appending(path: "\(id).zip").path], timeout: 600))?.status ?? 1) == 0
        let sidecar = root.appending(path: "\(id).json")
        if var meta = try? JSONDecoder().decode(Backup.self, from: Data(contentsOf: sidecar)) {
            meta.verified = ok
            try writeSidecar(root: root, meta: meta)
        }
        return ok
    }

    /// Smart retention for zip backups (pre-restore ones are spared).
    @discardableResult
    static func pruneTiered(dir: URL, recentHours: Int, dailyDays: Int, now: Int64 = Int64(Date().timeIntervalSince1970)) -> [Retention.PruneFailure] {
        let prunable = list(dir: dir).filter { $0.trigger != "pre-restore" && $0.trigger != "imported" }
        let keep = Retention.tieredKeepIDs(prunable.map { ($0.id, $0.createdAt) }, now: now,
                                           recentHours: recentHours, dailyDays: dailyDays)
        let protected = Retention.protectedIDs(prunable.map { ($0.id, $0.createdAt, $0.pinned) })
        var failures: [Retention.PruneFailure] = []
        for b in prunable where !keep.contains(b.id) && !protected.contains(b.id) {
            do { try delete(dir: dir, id: b.id) }
            catch { failures.append(.init(id: b.id, message: error.localizedDescription)) }
        }
        Retention.log(failures, kind: "backup")
        return failures
    }

    /// The one pruning decision every backup path uses (like Rust's
    /// `prune_backups`): a tiered config -> smart retention,
    /// otherwise keep the newest N.
    static func applyRetention(dir: URL) {
        if let t = AppDefaults.backupTiered {
            pruneTiered(dir: dir, recentHours: t.recentHours, dailyDays: t.dailyDays)
        } else {
            prune(dir: dir, keep: AppDefaults.backupKeep)
        }
    }

    // MARK: - Restore

    /// Restore a backup over the server folder. The caller MUST ensure
    /// the server is stopped. Always takes a fresh `pre-restore` backup
    /// and moves the current contents aside first — nothing is deleted.
    static func restore(dir: URL, id: String, progress: (String) -> Void) throws {
        let id = try ServerFileCollector.sanitizeID(id)
        let root = backupRoot(dir)
        let zipPath = root.appending(path: "\(id).zip")
        guard FileManager.default.fileExists(atPath: zipPath.path) else {
            throw RconServiceError.message("That backup no longer exists.")
        }

        progress("Backing up the current state first…")
        _ = try backupNow(dir: dir, label: "before restore", trigger: "pre-restore", progress: progress)

        progress("Moving the current folder aside…")
        let aside = dir.appending(path: "\(ServerFileCollector.preRestorePrefix)\(Int64(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        let fm = FileManager.default
        func isInfra(_ name: String) -> Bool {
            name == ServerFileCollector.backupDirName || name.hasPrefix(ServerFileCollector.preRestorePrefix)
        }
        /// Undo a half-done restore: quarantine whatever got extracted (never
        /// deleted), then move the original files back where they were.
        func rollback() {
            let failed = dir.appending(path: "\(ServerFileCollector.preRestorePrefix)failed-\(Int64(Date().timeIntervalSince1970))")
            try? fm.createDirectory(at: failed, withIntermediateDirectories: true)
            for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where !isInfra(entry.lastPathComponent) {
                try? fm.moveItem(at: entry, to: failed.appending(path: entry.lastPathComponent))
            }
            for entry in (try? fm.contentsOfDirectory(at: aside, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.moveItem(at: entry, to: dir.appending(path: entry.lastPathComponent))
            }
            if ((try? fm.contentsOfDirectory(atPath: aside.path)) ?? ["x"]).isEmpty { try? fm.removeItem(at: aside) }
        }
        if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for entry in entries where !isInfra(entry.lastPathComponent) {
                let name = entry.lastPathComponent
                do {
                    try fm.moveItem(at: entry, to: aside.appending(path: name))
                } catch {
                    rollback()
                    throw RconServiceError.message("couldn't move \(name) aside: \(error.localizedDescription)")
                }
            }
        }

        progress("Extracting the backup…")
        do {
            try runUnzip(zip: zipPath, into: dir)
        } catch {
            rollback()
            throw RconServiceError.message("\(error.localizedDescription) — your server folder was put back as it was.")
        }
        progress("Restored. The previous state is in \(aside.lastPathComponent)")
    }

    private static func runUnzip(zip: URL, into dir: URL) throws {
        let r = try Subprocess.run("/usr/bin/unzip", ["-o", "-q", zip.path, "-d", dir.path])
        // unzip exits 1 for benign warnings on some archives; only treat
        // >1 as a real failure, matching common CLI convention.
        guard r.status <= 1 else {
            let errText = r.stderrString
            throw RconServiceError.message("unzip failed: \(errText.isEmpty ? "exit \(r.status)" : errText)")
        }
    }
}
