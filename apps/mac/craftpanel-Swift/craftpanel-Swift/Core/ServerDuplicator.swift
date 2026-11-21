import Foundation

/// "Duplicate server" — copies a server's world, plugins/mods, and
/// configs into a new, independent folder (nothing about the original
/// changes), then hands back a ready-to-insert `ServerRecord`. Direct
/// port of the `clone_server` command. Reuses `ServerFileCollector`'s
/// own exclusion rules (no logs/backups/snapshots/trash/session file)
/// rather than re-deriving them — the same "don't copy regenerable junk"
/// rule backups already apply.
nonisolated struct DuplicateSource: Sendable {
    var path: String
    var serverType: ServerType
    var launchTarget: String
    var mcVersion: String?
    var javaPath: String
    var ramMB: UInt32

    init(_ record: ServerRecord) {
        // Extracted on the main actor, before crossing into a detached
        // task — a SwiftData model itself isn't safe to touch off-actor.
        path = record.path
        serverType = record.serverType
        launchTarget = record.launchTarget
        mcVersion = record.mcVersion
        javaPath = record.javaPath
        ramMB = record.ramMB
    }
}

nonisolated enum ServerDuplicator {
    /// Pure file-copy work, safe to run off the main actor. Returns the
    /// plain data the caller needs to build a `ServerRecord` back on the
    /// main actor — SwiftData models themselves aren't constructed here,
    /// since a bare `@Model` instance is safest kept to the actor that
    /// will actually insert it into a `ModelContext`.
    static func duplicate(from source: DuplicateSource, destination: URL) throws -> DuplicateSource {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RconServiceError.message("Something already exists at that location.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let sourceDir = URL(fileURLWithPath: source.path)
        // A clone is an independent server: no share code/lease, no install
        // attribution carried over (re-stamped by the caller).
        let notShared: Set<String> = ["craftpanel-share.json", "craftpanel-lease.json", ".craftpanel-meta.json"]
        for entry in ServerFileCollector.collect(dir: sourceDir) where !notShared.contains(entry.rel) {
            let dst = destination.appendingPathComponent(entry.rel)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: entry.url, to: dst)
        }

        var result = source
        result.path = destination.path
        return result
    }
}
