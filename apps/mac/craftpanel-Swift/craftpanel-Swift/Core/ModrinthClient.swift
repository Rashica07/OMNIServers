import Foundation
import CryptoKit

/// In-app content browser backed by the Modrinth API
/// (api.modrinth.com/v2). Search mods/plugins/datapacks, install with
/// required-dependency resolution, flag updates. Direct port of
/// `modrinth.rs`. Installs are tracked in
/// `<server>/.craftpanel-modrinth.json` so updates/removals stay clean.
nonisolated struct ModrinthHit: Sendable, Identifiable, Equatable {
    var id: String { projectID }
    var projectID: String
    var slug: String
    var title: String
    var description: String
    var downloads: Int
    var iconURL: String?
    var projectType: String
    var categories: [String]
    /// already installed by us
    var installed: Bool
    /// has a build for this server's Minecraft version
    var compatible: Bool
    /// "required" | "optional" | "unsupported" | "unknown"
    var serverSide: String
    var clientSide: String
}

nonisolated struct ModrinthSearchResult: Sendable {
    var hits: [ModrinthHit]
    var total: Int
}

nonisolated struct InstalledEntry: Codable, Sendable, Identifiable, Equatable {
    var id: String { projectID }
    var projectID: String
    var slug: String
    var title: String
    var filename: String
    var versionID: String
    var versionNumber: String
    /// installed as a dependency of another mod
    var dependency: Bool = false
    var update: UpdateInfo?

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id", slug, title, filename
        case versionID = "version_id", versionNumber = "version_number"
        case dependency, update
    }
}

nonisolated struct UpdateInfo: Codable, Sendable, Equatable {
    var versionID: String
    var versionNumber: String

    private enum CodingKeys: String, CodingKey {
        case versionID = "version_id", versionNumber = "version_number"
    }
}

nonisolated struct ModrinthInstallResult: Sendable {
    var installed: [String]
    var skipped: [String]
}

// MARK: - Modrinth response shapes (only the fields we need)

private nonisolated struct RawSearch: Decodable {
    var hits: [RawHit]
    var totalHits: Int
    private enum CodingKeys: String, CodingKey { case hits, totalHits = "total_hits" }
}
private nonisolated struct RawHit: Decodable {
    var projectID: String
    var slug: String
    var title: String
    var description: String
    var downloads: Int
    var iconURL: String?
    var projectType: String
    var categories: [String] = []
    /// all game versions any release of this project supports
    var versions: [String] = []
    var serverSide: String?
    var clientSide: String?
    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id", slug, title, description, downloads
        case iconURL = "icon_url", projectType = "project_type", categories, versions
        case serverSide = "server_side", clientSide = "client_side"
    }
}
private nonisolated struct RawVersion: Decodable {
    var id: String
    var versionNumber: String
    var files: [RawFile]
    var dependencies: [RawDep] = []
    private enum CodingKeys: String, CodingKey {
        case id, versionNumber = "version_number", files, dependencies
    }
}
private nonisolated struct RawFile: Decodable {
    var url: String
    var filename: String
    var primary: Bool = false
    var hashes: RawHashes
}
private nonisolated struct RawHashes: Decodable {
    var sha1: String?
}
private nonisolated struct RawDep: Decodable {
    var projectID: String?
    var versionID: String?
    var dependencyType: String
    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id", versionID = "version_id", dependencyType = "dependency_type"
    }
}
private nonisolated struct RawProject: Decodable {
    var id: String
    var slug: String
    var title: String
}
private nonisolated struct RawGalleryImage: Decodable {
    var url: String
}
private nonisolated struct RawProjectDetail: Decodable {
    var gallery: [RawGalleryImage] = []
}

nonisolated enum ModrinthClient {
    private static let api = "https://api.modrinth.com/v2"
    private static let userAgent = "CraftPanel/0.1 (minecraft server manager)"
    private static let manifestName = ".craftpanel-modrinth.json"

    // MARK: - Helpers

    private static func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw RconServiceError.message("Modrinth request failed: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RconServiceError.message("Modrinth returned bad JSON: \(error.localizedDescription)")
        }
    }

    /// "mod" / "plugin" (=modrinth "mod" + a paper/spigot loader), "datapack".
    static func loaderFacet(_ type: ServerType) -> String {
        switch type {
        case .fabric: "fabric"
        case .forge: "forge"
        case .neoforge: "neoforge"
        case .paper: "paper"
        case .spigot: "spigot"
        case .vanilla: "datapack"
        // Never actually called: the Add-ons tab is hidden entirely for
        // Bedrock servers -- this arm only exists so the switch is exhaustive.
        case .bedrock, .fivem, .terraria, .omnihost: "datapack"
        }
    }

    static func contentDir(_ dir: URL, serverType: ServerType, projectType: String) -> URL {
        if projectType == "datapack" {
            let level = Properties.load(dir: dir).getOr("level-name", "world")
            return dir.appending(path: level).appending(path: "datapacks")
        } else if serverType == .paper || serverType == .spigot {
            return dir.appending(path: "plugins")
        } else {
            return dir.appending(path: "mods")
        }
    }

    private static func manifestPath(_ dir: URL) -> URL { dir.appending(path: manifestName) }

    private static func readManifest(_ dir: URL) -> [InstalledEntry] {
        guard let data = try? Data(contentsOf: manifestPath(dir)),
              let list = try? JSONDecoder().decode([InstalledEntry].self, from: data) else {
            return []
        }
        return list
    }

    private static func writeManifest(_ dir: URL, _ list: [InstalledEntry]) throws {
        let data = try JSONEncoder().encode(list)
        try data.write(to: manifestPath(dir))
    }

    // MARK: - Search

    static func search(
        serverDir: URL, serverType: ServerType, query: String, projectType: String,
        category: String?, mcVersion: String?, offset: Int
    ) async throws -> ModrinthSearchResult {
        let lf = loaderFacet(serverType)
        // Modrinth's search index files real Paper/Spigot plugins under a
        // separate "plugin" project_type facet -- distinct from "mod" even
        // though hit objects still report project_type "mod" either way.
        // Confirmed live against the real API. Only the search facet needs
        // this translation.
        let searchProjectType = (projectType == "mod" && (serverType == .paper || serverType == .spigot))
            ? "plugin" : projectType

        var facets = ["[\"project_type:\(searchProjectType)\"]"]
        // Resource packs, like datapacks, aren't tied to a mod loader and
        // aren't "server_side" in the mods sense.
        if projectType != "datapack", projectType != "resourcepack" {
            facets.append("[\"categories:\(lf)\"]")
            facets.append("[\"server_side:required\",\"server_side:optional\"]")
        }
        if let c = category, !c.isEmpty {
            facets.append("[\"categories:\(c)\"]")
        }
        // no `versions:` facet -- show everything and mark what has no
        // build for this MC version, so nothing silently disappears.
        let facetsJSON = "[\(facets.joined(separator: ","))]"

        var comps = URLComponents(string: "\(api)/search")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "facets", value: facetsJSON),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "index", value: query.isEmpty ? "downloads" : "relevance"),
        ]
        guard let url = comps.url else { throw RconServiceError.message("bad search URL") }
        let raw: RawSearch = try await getJSON(url)

        let mine = Set(readManifest(serverDir).map(\.projectID))

        var hits = raw.hits.map { h -> ModrinthHit in
            let compatible = mcVersion.map { v in h.versions.contains(v) } ?? true
            return ModrinthHit(
                projectID: h.projectID, slug: h.slug, title: h.title, description: h.description,
                downloads: h.downloads, iconURL: h.iconURL, projectType: h.projectType,
                categories: h.categories, installed: mine.contains(h.projectID), compatible: compatible,
                serverSide: h.serverSide ?? "unknown", clientSide: h.clientSide ?? "unknown"
            )
        }
        // compatible first, keeping relevance order within each group
        hits = hits.enumerated().sorted { a, b in
            if a.element.compatible != b.element.compatible { return a.element.compatible && !b.element.compatible }
            return a.offset < b.offset
        }.map(\.element)

        return ModrinthSearchResult(hits: hits, total: raw.totalHits)
    }

    // MARK: - Install (with required-dep resolution)

    private static func bestVersion(project: String, loader: String, mcVersion: String?, projectType: String) async throws -> RawVersion {
        var urlString = "\(api)/project/\(project)/version"
        // datapacks have loader "datapack", resource packs have loader
        // "minecraft" -- mods/plugins use the real loader.
        let loaders = switch projectType {
        case "datapack": "datapack"
        case "resourcepack": "minecraft"
        default: loader
        }
        urlString += "?loaders=[\"\(loaders)\"]"
        if let v = mcVersion {
            urlString += "&game_versions=[\"\(v)\"]"
        }
        guard let url = URL(string: urlString) else { throw RconServiceError.message("bad version URL") }
        let versions: [RawVersion] = try await getJSON(url)
        guard let first = versions.first else {
            throw RconServiceError.message("no version of this compatible with your loader + Minecraft version")
        }
        return first
    }

    private static func downloadFile(_ f: RawFile, destDir: URL) async throws -> String {
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        guard let url = URL(string: f.url) else { throw RconServiceError.message("bad file URL") }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw RconServiceError.message("download failed: \(error.localizedDescription)")
        }
        if let want = f.hashes.sha1 {
            let got = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got == want else {
                throw RconServiceError.message("\(f.filename): checksum mismatch")
            }
        }
        try data.write(to: destDir.appending(path: try ServerFileCollector.safeFileName(f.filename)), options: .atomic)
        return f.filename
    }

    private static func primaryFile(_ v: RawVersion) -> RawFile? {
        v.files.first { $0.primary } ?? v.files.first
    }

    /// Every MC version a project has a build for on `loader` — port of
    /// `supported_versions` (Quick start picks the newest Paper version the
    /// template's plugin actually supports).
    static func supportedVersions(project: String, loader: String) async throws -> Set<String> {
        var c = URLComponents(string: "\(api)/project/\(project)/version")!
        c.queryItems = [URLQueryItem(name: "loaders", value: "[\"\(loader)\"]")]
        struct V: Decodable { var game_versions: [String] }
        let vs: [V] = try await getJSON(c.url!)
        return Set(vs.flatMap(\.game_versions))
    }

    static func install(
        serverDir: URL, serverType: ServerType, projectID: String, projectType: String, mcVersion: String?
    ) async throws -> ModrinthInstallResult {
        let loader = loaderFacet(serverType)
        var manifest = readManifest(serverDir)
        var have = Set(manifest.map(\.projectID))

        var installed: [String] = []
        var skipped: [String] = []
        var queue: [(id: String, isDep: Bool)] = [(projectID, false)]
        var seen = Set<String>()

        while let (pid, isDep) = queue.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if have.contains(pid) {
                skipped.append(pid)
                continue
            }
            guard let projURL = URL(string: "\(api)/project/\(pid)") else { continue }
            let proj: RawProject = try await getJSON(projURL)
            let ptype = isDep ? "mod" : projectType
            let ver: RawVersion
            do {
                ver = try await bestVersion(project: pid, loader: loader, mcVersion: mcVersion, projectType: ptype)
            } catch {
                throw RconServiceError.message("\(proj.title): \(error.localizedDescription)")
            }
            guard let file = primaryFile(ver) else {
                throw RconServiceError.message("\(proj.title): version has no file")
            }
            let dest = contentDir(serverDir, serverType: serverType, projectType: ptype)
            let filename = try await downloadFile(file, destDir: dest)

            manifest.append(InstalledEntry(
                projectID: proj.id, slug: proj.slug, title: proj.title, filename: filename,
                versionID: ver.id, versionNumber: ver.versionNumber, dependency: isDep, update: nil
            ))
            have.insert(proj.id)
            installed.append(proj.title)

            for d in ver.dependencies where d.dependencyType == "required" {
                if let dp = d.projectID {
                    queue.append((dp, true))
                } else if let vid = d.versionID, let vurl = URL(string: "\(api)/version/\(vid)") {
                    if let v: RawVersion = try? await getJSON(vurl), let f = primaryFile(v) {
                        _ = try? await downloadFile(f, destDir: contentDir(serverDir, serverType: serverType, projectType: "mod"))
                    }
                }
            }
        }

        try writeManifest(serverDir, manifest)
        return ModrinthInstallResult(installed: installed, skipped: skipped)
    }

    /// Set a Modrinth resource pack as this server's pack -- unlike
    /// `install()`, this never touches the mods/plugins folder or the
    /// install manifest. Modrinth's own version files already carry a
    /// SHA-1, so this skips downloading the zip a second time just to
    /// re-hash it.
    static func installResourcepack(
        serverDir: URL, projectID: String, mcVersion: String?, prompt: String, required: Bool
    ) async throws -> ResourcePackConfig {
        let ver = try await bestVersion(project: projectID, loader: "minecraft", mcVersion: mcVersion, projectType: "resourcepack")
        guard let file = primaryFile(ver) else {
            throw RconServiceError.message("That pack's version has no file.")
        }
        guard let sha1 = file.hashes.sha1 else {
            throw RconServiceError.message("Modrinth didn't publish a hash for that file.")
        }
        return try ResourcePackManager.setKnown(dir: serverDir, url: file.url, sha1: sha1, prompt: prompt, required: required)
    }

    /// Real screenshots for one project -- fetched on demand for one pack
    /// at a time, not eagerly for a whole page of hits.
    static func gallery(projectID: String) async throws -> [String] {
        guard let url = URL(string: "\(api)/project/\(projectID)") else { return [] }
        let detail: RawProjectDetail = try await getJSON(url)
        return detail.gallery.map(\.url)
    }

    // MARK: - Installed list + updates

    static func installed(serverDir: URL) -> [InstalledEntry] {
        readManifest(serverDir)
    }

    static func checkUpdates(serverDir: URL, serverType: ServerType, mcVersion: String?) async throws -> [InstalledEntry] {
        let loader = loaderFacet(serverType)
        var list = readManifest(serverDir)
        for i in list.indices {
            let ptype = list[i].filename.contains("datapack") ? "datapack" : "mod"
            if let v = try? await bestVersion(project: list[i].projectID, loader: loader, mcVersion: mcVersion, projectType: ptype) {
                list[i].update = (v.id != list[i].versionID) ? UpdateInfo(versionID: v.id, versionNumber: v.versionNumber) : nil
            }
        }
        try writeManifest(serverDir, list)
        return list
    }

    static func updateOne(serverDir: URL, serverType: ServerType, projectID: String, mcVersion: String?) async throws {
        let loader = loaderFacet(serverType)
        var list = readManifest(serverDir)
        guard let idx = list.firstIndex(where: { $0.projectID == projectID }) else {
            throw RconServiceError.message("not installed")
        }
        let ptype = list[idx].filename.contains("datapack") ? "datapack" : "mod"
        let ver = try await bestVersion(project: projectID, loader: loader, mcVersion: mcVersion, projectType: ptype)
        guard let file = primaryFile(ver) else { throw RconServiceError.message("no file") }
        let destDir = contentDir(serverDir, serverType: serverType, projectType: ptype)
        let old = destDir.appending(path: try ServerFileCollector.safeFileName(list[idx].filename))
        let trash = serverDir.appending(path: ".craftpanel-trash")
        // Trash the old jar (never delete); if the new download fails, put it back.
        let trashed = FileManager.default.fileExists(atPath: old.path)
            ? try ServerFileCollector.moveToTrash(old, trashDir: trash) : nil
        let filename: String
        do {
            filename = try await downloadFile(file, destDir: destDir)
        } catch {
            if let trashed { try? FileManager.default.moveItem(at: trashed, to: old) }
            throw error
        }
        list[idx].filename = filename
        list[idx].versionID = ver.id
        list[idx].versionNumber = ver.versionNumber
        list[idx].update = nil
        try writeManifest(serverDir, list)
    }

    static func removeOne(serverDir: URL, serverType: ServerType, projectID: String) throws {
        var list = readManifest(serverDir)
        guard let idx = list.firstIndex(where: { $0.projectID == projectID }) else {
            throw RconServiceError.message("not installed")
        }
        let e = list.remove(at: idx)
        let ptype = e.filename.contains("datapack") ? "datapack" : "mod"
        let fm = FileManager.default
        for base in [contentDir(serverDir, serverType: serverType, projectType: ptype), serverDir.appending(path: "mods-disabled")] {
            let p = base.appending(path: try ServerFileCollector.safeFileName(e.filename))
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            try ServerFileCollector.moveToTrash(p, trashDir: serverDir.appending(path: ".craftpanel-trash"))
        }
        try writeManifest(serverDir, list)
    }
}
