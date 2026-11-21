import Foundation

/// In-app file manager for a server folder: list / view / edit / rename /
/// delete / mkdir / import / export, plus a `logs/latest.log` tail.
/// Direct port of `files.rs`.
///
/// Every path is resolved relative to the server folder and rejected if
/// it escapes it (no `..`, no absolute, no symlink-out).
nonisolated struct FileEntry: Sendable, Identifiable, Equatable {
    var id: String { rel }
    var name: String
    var rel: String
    var isDir: Bool
    var size: UInt64
    var modified: Int64
}

nonisolated struct FileListing: Sendable {
    /// normalised rel path of the dir being listed ("" = server root)
    var path: String
    var parent: String?
    var entries: [FileEntry]
}

nonisolated struct FileView: Sendable {
    var rel: String
    var text: String
    var bytes: UInt64
    var truncated: Bool
    var binary: Bool
}

nonisolated enum ServerFileBrowser {
    private static let trash = ".craftpanel-trash"
    private static let maxTextBytes: UInt64 = 2 * 1024 * 1024

    /// Resolve `rel` under `root`, rejecting anything that would leave
    /// the folder -- no `..`, no absolute path component, and (once the
    /// target exists) no symlink escape either, matching the Rust
    /// source's component-walk + canonicalize-prefix check exactly.
    /// Confined absolute URL for `rel` (same checks as every other op).
    static func confinedURL(root: URL, rel: String) throws -> URL { try resolve(root: root, rel: rel) }

    private static func resolve(root: URL, rel: String) throws -> URL {
        var out = root
        let trimmed = rel.drop(while: { $0 == "/" || $0 == "\\" })
        for comp in trimmed.split(separator: "/") {
            if comp == "." { continue }
            if comp == ".." || comp.isEmpty { throw RconServiceError.message("That path isn't allowed.") }
            out = out.appendingPathComponent(String(comp))
        }
        // Canonicalize the nearest *existing* ancestor, so creating a new
        // file under a symlinked directory can't escape either (the Rust
        // source only checked when the target existed). Compare whole path
        // components: "/srv/mc2" must not pass as inside "/srv/mc".
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var probe = out
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > root.pathComponents.count {
            probe = probe.deletingLastPathComponent()
        }
        let canon = probe.resolvingSymlinksInPath().standardizedFileURL.path
        guard canon == base || canon.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw RconServiceError.message("That path escapes the server folder.")
        }
        return out
    }

    private static func normRel(root: URL, _ p: URL) -> String {
        ServerFileCollector.relativePath(of: p, from: root) ?? ""
    }

    static func list(root: URL, rel: String) throws -> FileListing {
        let dir = try resolve(root: root, rel: rel)
        var isDirFlag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirFlag), isDirFlag.boolValue else {
            throw RconServiceError.message("Not a folder.")
        }
        let fm = FileManager.default
        var entries: [FileEntry] = []
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names {
                let entryURL = dir.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: entryURL.path) else { continue }
                let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
                let size = isDir ? 0 : ((attrs[.size] as? NSNumber)?.uint64Value ?? 0)
                let modDate = attrs[.modificationDate] as? Date ?? .distantPast
                entries.append(FileEntry(
                    name: name, rel: normRel(root: root, entryURL), isDir: isDir,
                    size: size, modified: Int64(modDate.timeIntervalSince1970)
                ))
            }
        }
        entries.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.lowercased() < b.name.lowercased()
        }
        let path = normRel(root: root, dir)
        let parent: String? = path.isEmpty ? nil : (path.range(of: "/", options: .backwards).map { String(path[..<$0.lowerBound]) } ?? "")
        return FileListing(path: path, parent: parent, entries: entries)
    }

    static func read(root: URL, rel: String) throws -> FileView {
        let path = try resolve(root: root, rel: rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) else {
            throw RconServiceError.message("That file doesn't exist.")
        }
        if isDir.boolValue { throw RconServiceError.message("That's a folder.") }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let bytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        guard let handle = FileHandle(forReadingAtPath: path.path) else {
            throw RconServiceError.message("Couldn't open that file.")
        }
        defer { try? handle.close() }
        let raw = try handle.read(upToCount: Int(min(bytes, maxTextBytes))) ?? Data()
        let binary = raw.contains(0)
        return FileView(
            rel: normRel(root: root, path),
            text: binary ? "" : String(decoding: raw, as: UTF8.self),
            bytes: bytes, truncated: bytes > maxTextBytes, binary: binary
        )
    }

    static func write(root: URL, rel: String, content: String) throws {
        guard !rel.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RconServiceError.message("No file given.")
        }
        let path = try resolve(root: root, rel: rel)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue {
            throw RconServiceError.message("That's a folder.")
        }
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    static func mkdir(root: URL, rel: String) throws {
        guard !rel.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RconServiceError.message("No name given.")
        }
        let path = try resolve(root: root, rel: rel)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }

    static func rename(root: URL, from: String, to: String) throws {
        guard !from.trimmingCharacters(in: .whitespaces).isEmpty, !to.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RconServiceError.message("Both names are required.")
        }
        let src = try resolve(root: root, rel: from)
        let dst = try resolve(root: root, rel: to)
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { throw RconServiceError.message("Source no longer exists.") }
        guard !fm.fileExists(atPath: dst.path) else { throw RconServiceError.message("Something with that name already exists.") }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
    }

    /// Move to `.craftpanel-trash/<ts>-<name>` -- never a hard delete.
    static func delete(root: URL, rel: String) throws {
        guard !rel.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RconServiceError.message("Nothing selected.")
        }
        let path = try resolve(root: root, rel: rel)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { throw RconServiceError.message("That's already gone.") }
        let name = path.lastPathComponent
        let trashDir = root.appendingPathComponent(trash)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let dst = trashDir.appendingPathComponent("\(Int64(Date().timeIntervalSince1970))-\(name)")
        try fm.moveItem(at: path, to: dst)
    }

    @discardableResult
    static func importFiles(root: URL, dirRel: String, sources: [URL]) throws -> [String] {
        let dir = try resolve(root: root, rel: dirRel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw RconServiceError.message("Target isn't a folder.")
        }
        var added: [String] = []
        for src in sources {
            let name = src.lastPathComponent
            do {
                try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(name))
                added.append(name)
            } catch {
                throw RconServiceError.message("\(name): \(error.localizedDescription)")
            }
        }
        return added
    }

    static func export(root: URL, rel: String, dest: URL) throws {
        let src = try resolve(root: root, rel: rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else {
            throw RconServiceError.message("Only files can be downloaded.")
        }
        try FileManager.default.copyItem(at: src, to: dest)
    }

    /// Last `maxLines` of a log file (default `logs/latest.log`).
    static func tail(root: URL, rel: String?, maxLines: Int) throws -> String {
        let rel = (rel?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "logs/latest.log"
        let path = try resolve(root: root, rel: rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), !isDir.boolValue else {
            throw RconServiceError.message("No \(rel) yet.")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let start = size > maxTextBytes ? size - maxTextBytes : 0

        guard let handle = FileHandle(forReadingAtPath: path.path) else {
            throw RconServiceError.message("Couldn't open \(rel).")
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        let bytes = try handle.readToEnd() ?? Data()
        let text = String(decoding: bytes, as: UTF8.self)
        // `.components(separatedBy:)` yields a trailing empty element for
        // a string ending in "\n" ("a\nb\n" -> ["a","b",""]); Rust's
        // `str::lines()` doesn't. Drop it here so a log file's normal
        // trailing newline doesn't push a real line out of the tail --
        // caught by a real test failure, not assumed.
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let tailLines = lines.suffix(maxLines)
        return tailLines.joined(separator: "\n")
    }
}
