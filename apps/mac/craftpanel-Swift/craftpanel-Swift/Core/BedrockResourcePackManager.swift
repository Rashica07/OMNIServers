import Foundation

/// Bedrock's resource packs — a completely different system from Java's
/// single URL+SHA1 slot (`ResourcePackManager`/`ResourcePackCard`):
/// each pack is its own unzipped folder under `resource_packs/`, described
/// by a `manifest.json`, and referenced by UUID from a world's own
/// `world_resource_packs.json`. `resourcepack.rs`'s own doc comment flags
/// this as a "completely different, folder-based system" the frontend
/// hides entirely for Bedrock servers — this is the real, previously
/// unbuilt gap "resource pack viewer and deleter" closes, not a rework of
/// the Java URL-slot feature (which already has its own manager/card).
enum BedrockResourcePackManager {
    private static let trash = ".craftpanel-trash"

    /// The real Bedrock manifest shape (`format_version`/`header`/
    /// `modules`) — only the fields this app actually reads.
    private struct Manifest: Codable {
        struct Header: Codable {
            var name: String
            var uuid: String
            var version: [Int]?
            var description: String?
        }
        var header: Header
    }

    /// One folder in `resource_packs/` with a valid `manifest.json`.
    /// Folders without one (a stray `.DS_Store`, a half-downloaded pack)
    /// are silently skipped rather than shown as a broken entry.
    struct Pack: Identifiable, Sendable, Equatable {
        var id: String // the manifest's own uuid — what world configs reference
        var name: String
        var description: String?
        var versionLabel: String
        var folderName: String
        var folderURL: URL
        var iconURL: URL?
    }

    static func list(serverDir: URL) -> [Pack] {
        let dir = serverDir.appending(path: "resource_packs")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var packs: [Pack] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = entry.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            let iconURL = entry.appending(path: "pack_icon.png")
            let versionLabel = manifest.header.version?.map(String.init).joined(separator: ".") ?? ""
            packs.append(Pack(
                id: manifest.header.uuid,
                name: manifest.header.name,
                description: manifest.header.description,
                versionLabel: versionLabel,
                folderName: entry.lastPathComponent,
                folderURL: entry,
                iconURL: fm.fileExists(atPath: iconURL.path) ? iconURL : nil
            ))
        }
        return packs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Moves the pack's folder to `.craftpanel-trash/<ts>-<name>` — same
    /// never-a-hard-delete convention `ServerFileBrowser.delete` uses —
    /// then best-effort drops its UUID from any `world_resource_packs.json`
    /// found under the server directory, so a deleted pack doesn't leave a
    /// world referencing a folder that's no longer there. The trash move
    /// is the operation that matters; the world-config cleanup is a nice-
    /// to-have that's allowed to no-op quietly if the file isn't where
    /// expected.
    static func delete(serverDir: URL, pack: Pack) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pack.folderURL.path) else {
            throw RconServiceError.message("That pack is already gone.")
        }
        let trashDir = serverDir.appending(path: trash)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let dst = trashDir.appending(path: "\(Int64(Date().timeIntervalSince1970))-\(pack.folderName)")
        try fm.moveItem(at: pack.folderURL, to: dst)
        pruneWorldReferences(serverDir: serverDir, packID: pack.id)
    }

    /// `world_resource_packs.json` lives per-world (`worlds/<name>/`), and
    /// occasionally at the server root — checked shallowly (server root +
    /// direct children of `worlds/`), matching every entry's `pack_id`
    /// case-insensitively since UUIDs aren't guaranteed consistent case.
    private static func pruneWorldReferences(serverDir: URL, packID: String) {
        let fm = FileManager.default
        var candidates: [URL] = []
        let rootConfig = serverDir.appending(path: "world_resource_packs.json")
        if fm.fileExists(atPath: rootConfig.path) { candidates.append(rootConfig) }
        let worldsDir = serverDir.appending(path: "worlds")
        if let worldFolders = try? fm.contentsOfDirectory(at: worldsDir, includingPropertiesForKeys: nil) {
            for world in worldFolders {
                let config = world.appending(path: "world_resource_packs.json")
                if fm.fileExists(atPath: config.path) { candidates.append(config) }
            }
        }
        for file in candidates {
            guard let data = try? Data(contentsOf: file),
                  var entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll { ($0["pack_id"] as? String)?.caseInsensitiveCompare(packID) == .orderedSame }
            guard entries.count != before,
                  let out = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted]) else { continue }
            try? out.write(to: file)
        }
    }
}
