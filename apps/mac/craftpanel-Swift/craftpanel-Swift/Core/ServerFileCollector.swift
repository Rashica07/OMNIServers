import Foundation

/// Files worth carrying into a backup or snapshot — the same
/// "regenerable junk" filter shared by `backups.rs`/`snapshots.rs`'s
/// `collect_files`/`excluded`. Never includes OMNIServers's own backup or
/// snapshot stores, logs, crash reports, the trash folder, lock files,
/// the session file, or `.DS_Store`.
nonisolated enum ServerFileCollector {
    static let backupDirName = "craftpanel-backups"
    static let snapshotDirName = "craftpanel-snapshots"
    static let preRestorePrefix = ".craftpanel-pre-restore-"

    /// Returns (absoluteURL, relativePath) pairs for every file worth
    /// backing up, relative path using "/" separators regardless of
    /// platform (matches the Rust source's explicit backslash
    /// normalization, kept here even though macOS never produces one).
    static func collect(dir: URL) -> [(url: URL, rel: String)] {
        var out: [(URL, String)] = []
        let fm = FileManager.default
        // Deliberately NOT using .skipsHiddenFiles -- a real server
        // folder can have legitimate dotfiles worth backing up;
        // exclusion is handled explicitly by `excluded(_:)` instead.
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        for case let fileURL as URL in enumerator {
            guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isFile == true else { continue }
            guard let rel = relativePath(of: fileURL, from: dir) else { continue }
            if rel.isEmpty || excluded(rel) { continue }
            out.append((fileURL, rel))
        }
        return out
    }

    /// `child`'s path relative to `base`, computed by diffing standardized
    /// path components rather than stripping `base.path` as a raw string
    /// prefix. String-prefix stripping breaks the moment the two URLs
    /// disagree on symlink resolution — `/tmp` vs `/private/tmp` on macOS
    /// is exactly this trap, and a directory enumerator's child URLs
    /// don't always share the same resolved form as the base URL you
    /// started from. Reproduced as a real test failure (zip silently
    /// getting garbage relative paths and reporting "nothing to do"),
    /// not a theoretical concern.
    static func relativePath(of child: URL, from base: URL) -> String? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.count > baseComponents.count,
              Array(childComponents.prefix(baseComponents.count)) == baseComponents else {
            return nil
        }
        return childComponents.suffix(from: baseComponents.count).joined(separator: "/")
    }

    static func excluded(_ rel: String) -> Bool {
        let l = rel.lowercased()
        return l == backupDirName
            || l.hasPrefix("\(backupDirName)/")
            || l == snapshotDirName
            || l.hasPrefix("\(snapshotDirName)/")
            || l.hasPrefix(preRestorePrefix)
            || l == "logs"
            || l.hasPrefix("logs/")
            || l == "crash-reports"
            || l.hasPrefix("crash-reports/")
            || l.hasPrefix(".craftpanel-trash/")
            || l.hasPrefix(".craftpanel-staging-")
            || l == ".craftpanel-session.json"
            || l.hasSuffix(".lock")
            || l == ".ds_store"
            || l.hasSuffix("/.ds_store")
    }

    static func shortID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6))
    }

    /// A file name that came from outside (a mod API, a manifest on disk):
    /// must be a single path component. Rejects `../evil.jar`, `a/b`,
    /// absolute paths, NULs and hidden/dot names.
    static func safeFileName(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              !name.hasPrefix("."), name.trimmingCharacters(in: .whitespaces) == name
        else { throw RconServiceError.message("Refusing unsafe file name: \(name)") }
        return name
    }

    /// Move `item` into `trashDir` without ever deleting anything: on a name
    /// collision the trashed copy gets a timestamp suffix instead of the old
    /// copy being removed. Returns where it went.
    @discardableResult
    static func moveToTrash(_ item: URL, trashDir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        var dest = trashDir.appending(path: item.lastPathComponent)
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            let stem = item.deletingPathExtension().lastPathComponent
            let ext = item.pathExtension.isEmpty ? "" : ".\(item.pathExtension)"
            dest = trashDir.appending(path: "\(stem).\(Int(Date().timeIntervalSince1970))-\(n)\(ext)")
            n += 1
        }
        try fm.moveItem(at: item, to: dest)
        return dest
    }

    static func sanitizeID(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw RconServiceError.message("Bad backup id.")
        }
        return id
    }
}
