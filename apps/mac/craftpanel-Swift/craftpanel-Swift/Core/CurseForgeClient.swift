import Foundation
import CryptoKit

/// In-app content browser backed by the CurseForge Core API
/// (api.curseforge.com/v1) -- the mod/plugin catalog counterpart to
/// `ModrinthClient`, direct port of `curseforge.rs`. Same shape
/// deliberately: search / install with required-dependency resolution /
/// installed-list / update-check, tracked in its own
/// `<server>/.craftpanel-curseforge.json` manifest so the two sources
/// never collide.
///
/// **Scope of this first pass, stated plainly rather than faked**: mods
/// and Bukkit/Spigot/Paper plugins only -- same reasoning as the Rust
/// side's own doc comment: CurseForge's resource-pack/data-pack
/// categories aren't consistently tagged enough to build on with
/// confidence yet.
///
/// Every request needs an API key as the `x-api-key` header -- no
/// anonymous access. CurseForge issues that key to *the application*,
/// not to each person running it (confirmed by their own approval
/// email: "we've approved your application OMNIServers for the 3rd Party
/// CurseForge API") -- so unlike Modrinth, this is deliberately not a
/// per-user Settings field. OMNIServers is meant for people who've never
/// heard of an API key, the same way Aternos doesn't ask a player to go
/// register one -- so the key ships embedded in `embeddedAPIKey` below
/// and every install shares it, same as any app bundling its own vendor
/// API key (a Sentry DSN, a Maps key, ...). Matches `curseforge.rs`'s
/// own `EMBEDDED_API_KEY` exactly -- see that module's doc comment for
/// the honest tradeoff (extractable via `strings`, not a real secret in
/// the "protects something if leaked" sense; CurseForge's own console is
/// the actual control point if it ever needs rotating).
nonisolated struct CurseForgeHit: Sendable, Identifiable, Equatable {
    var id: String { String(modID) }
    var modID: Int64
    var slug: String
    var title: String
    var description: String
    var downloads: Int
    var iconURL: String?
    var projectType: String
    var categories: [String]
    var installed: Bool
    var compatible: Bool
}

nonisolated struct CurseForgeSearchResult: Sendable {
    var hits: [CurseForgeHit]
    var total: Int
}

nonisolated struct CurseForgeInstalledEntry: Codable, Sendable, Identifiable, Equatable {
    var id: String { String(modID) }
    var modID: Int64
    var slug: String
    var title: String
    var filename: String
    var fileID: Int64
    var dependency: Bool = false
    var update: CurseForgeUpdateInfo?

    private enum CodingKeys: String, CodingKey {
        case modID = "mod_id", slug, title, filename, fileID = "file_id", dependency, update
    }
}

nonisolated struct CurseForgeUpdateInfo: Codable, Sendable, Equatable {
    var fileID: Int64
    var filename: String
    private enum CodingKeys: String, CodingKey { case fileID = "file_id", filename }
}

nonisolated struct CurseForgeInstallResult: Sendable {
    var installed: [String]
    var skipped: [String]
}

// MARK: - CurseForge response shapes (only the fields we need)

private nonisolated struct Envelope<T: Decodable>: Decodable { var data: T }
private nonisolated struct RawPagination: Decodable { var totalCount: Int
    private enum CodingKeys: String, CodingKey { case totalCount = "totalCount" }
}
private nonisolated struct RawSearch: Decodable { var data: [RawMod]; var pagination: RawPagination }
private nonisolated struct RawLogo: Decodable { var url: String }
private nonisolated struct RawFileIndex: Decodable { var gameVersion: String
    private enum CodingKeys: String, CodingKey { case gameVersion = "gameVersion" }
}
private nonisolated struct RawCategory: Decodable { var name: String }
private nonisolated struct RawMod: Decodable {
    var id: Int64
    var slug: String
    var name: String
    var summary: String = ""
    var downloadCount: Double
    var logo: RawLogo?
    var categories: [RawCategory] = []
    var latestFilesIndexes: [RawFileIndex] = []
    private enum CodingKeys: String, CodingKey {
        case id, slug, name, summary
        case downloadCount = "downloadCount", logo, categories
        case latestFilesIndexes = "latestFilesIndexes"
    }
}
private nonisolated struct RawGameCategory: Decodable {
    var id: Int64
    var name: String
    var classID: Int64?
    var isClass: Bool = false
    private enum CodingKeys: String, CodingKey {
        case id, name, classID = "classId", isClass = "isClass"
    }
}
private nonisolated struct RawHash: Decodable { var value: String; var algo: Int } // 1 = Sha1, 2 = Md5
private nonisolated struct RawDependency: Decodable {
    var modID: Int64
    var relationType: Int
    private enum CodingKeys: String, CodingKey { case modID = "modId", relationType = "relationType" }
}
private nonisolated struct RawFile: Decodable {
    var id: Int64
    var fileName: String
    var downloadURL: String?
    var hashes: [RawHash] = []
    var dependencies: [RawDependency] = []
    private enum CodingKeys: String, CodingKey {
        case id, fileName = "fileName", downloadURL = "downloadUrl", hashes, dependencies
    }
}

nonisolated enum CurseForgeClient {
    private static let api = "https://api.curseforge.com/v1"
    private static let userAgent = "CraftPanel/0.1 (minecraft server manager)"
    private static let manifestName = ".craftpanel-curseforge.json"

    /// OMNIServers's CurseForge Core API key. Kept out of source: it is read
    /// from `Secrets.plist` (key `CurseForgeAPIKey`), a gitignored file that
    /// Xcode bundles as a resource. Missing file -> empty key -> the existing
    /// "add your CurseForge API key" error instead of a crash. An environment
    /// variable `CURSEFORGE_API_KEY` wins, so tests/CI can inject one.
    static let embeddedAPIKey: String = {
        if let env = ProcessInfo.processInfo.environment["CURSEFORGE_API_KEY"], !env.isEmpty { return env }
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let key = dict["CurseForgeAPIKey"] as? String else { return "" }
        return key
    }()
    /// CurseForge's own numeric id for the Minecraft game -- stable,
    /// public, baked into their whole URL scheme.
    private static let minecraftGameID = 432
    /// CurseForge's file-relation enum for "requires this mod too".
    private static let relationRequiredDependency = 3

    // MARK: - Helpers

    private static func getJSON<T: Decodable>(_ url: URL, apiKey: String) async throws -> T {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RconServiceError.message("Add your CurseForge API key in OMNIServers Settings first.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw RconServiceError.message("CurseForge request failed: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RconServiceError.message("CurseForge returned bad JSON: \(error.localizedDescription)")
        }
    }

    /// "mod" -> CurseForge's "Bukkit Plugins" class for Paper/Spigot
    /// servers, "Mods" otherwise -- resolved by name against the live
    /// category list rather than a hardcoded classId, same reasoning as
    /// the Rust side: not worth guessing at from memory when a plain GET
    /// settles it exactly.
    private static func classID(for projectType: String, serverType: ServerType, apiKey: String) async throws -> Int64 {
        guard projectType == "mod" else {
            throw RconServiceError.message("CurseForge browsing isn't offered for \(projectType) yet -- try Modrinth for that.")
        }
        let want = (serverType == .paper || serverType == .spigot) ? "Bukkit Plugins" : "Mods"
        guard let url = URL(string: "\(api)/categories?gameId=\(minecraftGameID)") else {
            throw RconServiceError.message("bad categories URL")
        }
        let env: Envelope<[RawGameCategory]> = try await getJSON(url, apiKey: apiKey)
        guard let cat = env.data.first(where: { $0.isClass && $0.name.caseInsensitiveCompare(want) == .orderedSame }) else {
            throw RconServiceError.message("CurseForge doesn't list a \"\(want)\" category right now.")
        }
        return cat.id
    }

    private static func manifestPath(_ dir: URL) -> URL { dir.appending(path: manifestName) }

    private static func readManifest(_ dir: URL) -> [CurseForgeInstalledEntry] {
        guard let data = try? Data(contentsOf: manifestPath(dir)),
              let list = try? JSONDecoder().decode([CurseForgeInstalledEntry].self, from: data) else {
            return []
        }
        return list
    }

    private static func writeManifest(_ dir: URL, _ list: [CurseForgeInstalledEntry]) throws {
        let data = try JSONEncoder().encode(list)
        try data.write(to: manifestPath(dir))
    }

    private static func contentDir(_ dir: URL, serverType: ServerType) -> URL {
        (serverType == .paper || serverType == .spigot)
            ? dir.appending(path: "plugins")
            : dir.appending(path: "mods")
    }

    // MARK: - Search

    static func search(
        serverDir: URL, serverType: ServerType, query: String, projectType: String,
        mcVersion: String?, offset: Int, apiKey: String
    ) async throws -> CurseForgeSearchResult {
        let cid = try await classID(for: projectType, serverType: serverType, apiKey: apiKey)

        var comps = URLComponents(string: "\(api)/mods/search")!
        var items = [
            URLQueryItem(name: "gameId", value: String(minecraftGameID)),
            URLQueryItem(name: "classId", value: String(cid)),
            URLQueryItem(name: "searchFilter", value: query),
            URLQueryItem(name: "sortField", value: "2"),
            URLQueryItem(name: "sortOrder", value: "desc"),
            URLQueryItem(name: "pageSize", value: "30"),
            URLQueryItem(name: "index", value: String(offset)),
        ]
        // No `modLoaderType` filter, deliberately -- same "show
        // everything, mark what doesn't fit" policy as Modrinth, rather
        // than hardcode CurseForge's undocumented loader-type enum.
        if let v = mcVersion { items.append(URLQueryItem(name: "gameVersion", value: v)) }
        comps.queryItems = items
        guard let url = comps.url else { throw RconServiceError.message("bad search URL") }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw RconServiceError.message("search failed: \(error.localizedDescription)")
        }
        let raw: RawSearch
        do {
            raw = try JSONDecoder().decode(RawSearch.self, from: data)
        } catch {
            throw RconServiceError.message("bad search JSON: \(error.localizedDescription)")
        }

        let mine = Set(readManifest(serverDir).map(\.modID))
        let ptypeLabel = (serverType == .paper || serverType == .spigot) ? "plugin" : "mod"

        var hits = raw.data.map { m -> CurseForgeHit in
            let compatible = mcVersion.map { v in m.latestFilesIndexes.contains { $0.gameVersion == v } } ?? true
            return CurseForgeHit(
                modID: m.id, slug: m.slug, title: m.name, description: m.summary,
                downloads: max(0, Int(m.downloadCount)), iconURL: m.logo?.url, projectType: ptypeLabel,
                categories: m.categories.map(\.name), installed: mine.contains(m.id), compatible: compatible
            )
        }
        hits = hits.enumerated().sorted { a, b in
            if a.element.compatible != b.element.compatible { return a.element.compatible && !b.element.compatible }
            return a.offset < b.offset
        }.map(\.element)

        return CurseForgeSearchResult(hits: hits, total: raw.pagination.totalCount)
    }

    // MARK: - Install (with required-dep resolution)

    private static func bestFile(modID: Int64, mcVersion: String?, apiKey: String) async throws -> RawFile {
        var comps = URLComponents(string: "\(api)/mods/\(modID)/files")!
        var items = [URLQueryItem(name: "pageSize", value: "50")]
        if let v = mcVersion { items.append(URLQueryItem(name: "gameVersion", value: v)) }
        comps.queryItems = items
        guard let url = comps.url else { throw RconServiceError.message("bad files URL") }
        let env: Envelope<[RawFile]> = try await getJSON(url, apiKey: apiKey)
        guard let first = env.data.first else {
            throw RconServiceError.message("no file of this compatible with your Minecraft version")
        }
        return first
    }

    private static func downloadFile(_ f: RawFile, destDir: URL, apiKey: String) async throws -> String {
        guard let urlString = f.downloadURL, let url = URL(string: urlString) else {
            throw RconServiceError.message("\(f.fileName): the author has disabled third-party downloads for this file -- install it manually from curseforge.com.")
        }
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        var request = URLRequest(url: url, timeoutInterval: 120)
        // The file CDN (edge.forgecdn.net) is public; only api.curseforge.com gets the key.
        if url.host == "api.curseforge.com" { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw RconServiceError.message("download failed: \(error.localizedDescription)")
        }
        if let sha1 = f.hashes.first(where: { $0.algo == 1 })?.value {
            let got = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got == sha1 else { throw RconServiceError.message("\(f.fileName): checksum mismatch") }
        }
        try data.write(to: destDir.appending(path: try ServerFileCollector.safeFileName(f.fileName)), options: .atomic)
        return f.fileName
    }

    static func install(
        serverDir: URL, serverType: ServerType, modID: Int64, mcVersion: String?, apiKey: String
    ) async throws -> CurseForgeInstallResult {
        var manifest = readManifest(serverDir)
        var have = Set(manifest.map(\.modID))

        var installed: [String] = []
        var skipped: [String] = []
        var queue: [(id: Int64, isDep: Bool)] = [(modID, false)]
        var seen = Set<Int64>()
        let dest = contentDir(serverDir, serverType: serverType)

        while let (mid, isDep) = queue.popLast() {
            guard seen.insert(mid).inserted else { continue }
            if have.contains(mid) {
                skipped.append(String(mid))
                continue
            }
            let file = try await bestFile(modID: mid, mcVersion: mcVersion, apiKey: apiKey)
            guard let modURL = URL(string: "\(api)/mods/\(mid)") else { continue }
            let env: Envelope<RawMod> = try await getJSON(modURL, apiKey: apiKey)
            let title = env.data
            let filename = try await downloadFile(file, destDir: dest, apiKey: apiKey)

            manifest.append(CurseForgeInstalledEntry(
                modID: mid, slug: title.slug, title: title.name, filename: filename,
                fileID: file.id, dependency: isDep, update: nil
            ))
            have.insert(mid)
            installed.append(title.name)

            for d in file.dependencies where d.relationType == relationRequiredDependency {
                queue.append((d.modID, true))
            }
        }

        try writeManifest(serverDir, manifest)
        return CurseForgeInstallResult(installed: installed, skipped: skipped)
    }

    // MARK: - Installed list + updates

    static func installed(serverDir: URL) -> [CurseForgeInstalledEntry] {
        readManifest(serverDir)
    }

    static func checkUpdates(serverDir: URL, mcVersion: String?, apiKey: String) async throws -> [CurseForgeInstalledEntry] {
        var list = readManifest(serverDir)
        for i in list.indices {
            if let f = try? await bestFile(modID: list[i].modID, mcVersion: mcVersion, apiKey: apiKey) {
                list[i].update = (f.id != list[i].fileID) ? CurseForgeUpdateInfo(fileID: f.id, filename: f.fileName) : nil
            }
        }
        try writeManifest(serverDir, list)
        return list
    }

    static func updateOne(serverDir: URL, serverType: ServerType, modID: Int64, mcVersion: String?, apiKey: String) async throws {
        var list = readManifest(serverDir)
        guard let idx = list.firstIndex(where: { $0.modID == modID }) else {
            throw RconServiceError.message("not installed")
        }
        let file = try await bestFile(modID: modID, mcVersion: mcVersion, apiKey: apiKey)
        let destDir = contentDir(serverDir, serverType: serverType)
        let old = destDir.appending(path: try ServerFileCollector.safeFileName(list[idx].filename))
        let trash = serverDir.appending(path: ".craftpanel-trash")
        // Trash the old jar (never delete); if the new download fails, put it back.
        let trashed = FileManager.default.fileExists(atPath: old.path)
            ? try ServerFileCollector.moveToTrash(old, trashDir: trash) : nil
        let filename: String
        do {
            filename = try await downloadFile(file, destDir: destDir, apiKey: apiKey)
        } catch {
            if let trashed { try? FileManager.default.moveItem(at: trashed, to: old) }
            throw error
        }
        list[idx].filename = filename
        list[idx].fileID = file.id
        list[idx].update = nil
        try writeManifest(serverDir, list)
    }

    static func removeOne(serverDir: URL, serverType: ServerType, modID: Int64) throws {
        var list = readManifest(serverDir)
        guard let idx = list.firstIndex(where: { $0.modID == modID }) else {
            throw RconServiceError.message("not installed")
        }
        let e = list.remove(at: idx)
        let fm = FileManager.default
        for base in [contentDir(serverDir, serverType: serverType), serverDir.appending(path: "mods-disabled")] {
            let p = base.appending(path: try ServerFileCollector.safeFileName(e.filename))
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            try ServerFileCollector.moveToTrash(p, trashDir: serverDir.appending(path: ".craftpanel-trash"))
        }
        try writeManifest(serverDir, list)
    }
}
