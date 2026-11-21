import Foundation

/// Create a server from a Modrinth modpack (`.mrpack`) — port of
/// `provision::create_from_modpack` / `modpack_search` / `modpack_info`.
///
/// Hardening beyond the Rust version (backport candidates):
/// * pack file downloads must be https and on the mrpack spec's allowed
///   hosts, and every file must carry a hash that we check;
/// * overrides are extracted to a scratch folder and merged in as regular
///   files/folders only — a symlink inside a pack is never recreated, so it
///   can't be used to write outside the server folder.
nonisolated enum Modpacks {
    struct Hit: Sendable, Identifiable, Decodable {
        var projectID: String
        var title: String
        var description: String
        var iconURL: String?
        var downloads: Int
        var id: String { projectID }
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id", title, description, iconURL = "icon_url", downloads
        }
    }

    struct Index: Decodable {
        struct File: Decodable {
            struct Hashes: Decodable { var sha1: String?; var sha512: String? }
            struct Env: Decodable { var server: String? }
            var path: String
            var hashes: Hashes
            var env: Env?
            var downloads: [String]
        }
        var files: [File]
        var dependencies: [String: String]
    }

    static let allowedHosts: Set<String> = ["cdn.modrinth.com", "github.com", "raw.githubusercontent.com", "gitlab.com"]

    static func search(_ query: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://api.modrinth.com/v2/search")!
        c.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "facets", value: #"[["project_type:modpack"]]"#),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "index", value: query.isEmpty ? "downloads" : "relevance"),
        ]
        struct R: Decodable { var hits: [Hit] }
        let (d, _) = try await URLSession.shared.data(for: request(c.url!))
        return try JSONDecoder().decode(R.self, from: d).hits
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("CraftPanel/0.1 modpack", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Only a file with an explicit "unsupported" server env is skipped.
    static func serverWants(_ f: Index.File) -> Bool { f.env?.server != "unsupported" }

    /// Plain contained relative path — pack file lists are untrusted input.
    static func safeRelativePath(_ p: String) -> Bool {
        let comps = p.split(separator: "/", omittingEmptySubsequences: false)
        return !p.isEmpty && !p.hasPrefix("/") && !p.contains("\0") && !p.contains("\\")
            && !comps.contains("..") && !comps.contains("")
    }

    static func downloadAllowed(_ s: String) -> URL? {
        guard let u = URL(string: s), u.scheme == "https", let h = u.host, allowedHosts.contains(h) else { return nil }
        return u
    }

    /// Returns the created server; the caller registers it.
    static func create(projectID: String, dir: URL, name: String, ramMB: UInt32, javaPath: String?, takenPorts: Set<UInt16>,
                       progress: @escaping (ProvisionProgress) -> Void) async throws -> Created {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let e = try? fm.contentsOfDirectory(atPath: dir.path), !e.isEmpty {
            throw ProvisionError.message("That folder isn't empty — pick a fresh folder for a new server.")
        }
        var java = (javaPath?.isEmpty == false) ? javaPath! : "java"

        progress(ProvisionProgress(stage: "fetch", message: "Looking up the modpack…", pct: nil))
        guard let versions = try await Provisioner.getJSON("https://api.modrinth.com/v2/project/\(projectID)/version") as? [[String: Any]],
              let version = versions.first, let files = version["files"] as? [[String: Any]], !files.isEmpty else {
            throw ProvisionError.message("This modpack has no published versions.")
        }
        let primary = files.first { $0["primary"] as? Bool == true } ?? files[0]
        guard let url = primary["url"] as? String else { throw ProvisionError.message("Modpack file has no download URL.") }
        let wantSHA1 = (primary["hashes"] as? [String: Any])?["sha1"] as? String ?? ""

        let scratch = fm.temporaryDirectory.appending(path: "craftpanel-modpack-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let archive = scratch.appending(path: "pack.mrpack")
        try await Provisioner.downloadTo(url, dest: archive, label: "the modpack", progress: progress)
        if !wantSHA1.isEmpty, try Provisioner.sha1Hex(archive) != wantSHA1 {
            throw ProvisionError.message("Modpack checksum mismatch — deleted rather than trust it.")
        }

        progress(ProvisionProgress(stage: "index", message: "Reading the modpack manifest…", pct: nil))
        let idx = try Subprocess.run("/usr/bin/unzip", ["-p", archive.path, "modrinth.index.json"], timeout: 60)
        guard idx.status == 0, let index = try? JSONDecoder().decode(Index.self, from: idx.stdout) else {
            throw ProvisionError.message("This file doesn't look like a Modrinth modpack (.mrpack).")
        }
        guard let mc = index.dependencies["minecraft"] else {
            throw ProvisionError.message("This modpack doesn't specify a Minecraft version.")
        }
        let (loader, loaderVersion): (Loader, String?)
        if let v = index.dependencies["fabric-loader"] { (loader, loaderVersion) = (.fabric, v) }
        else if let v = index.dependencies["neoforge"] { (loader, loaderVersion) = (.neoforge, v) }
        else if let v = index.dependencies["forge"] { (loader, loaderVersion) = (.forge, "\(mc)-\(v)") }
        else if index.dependencies["quilt-loader"] != nil {
            throw ProvisionError.message("This modpack needs Quilt, which OMNIServers doesn't provision yet.")
        } else { (loader, loaderVersion) = (.vanilla, nil) }

        java = try await Provisioner.ensureJava(java, need: JavaProbe.requiredJava(forMC: mc), mcVersion: mc, progress: progress)
        let spec = CreateSpec(loader: loader, mcVersion: mc, loaderVersion: loaderVersion, dir: dir, name: name,
                              ramMB: ramMB, javaPath: java)
        progress(ProvisionProgress(stage: "loader", message: "Setting up \(loader.label) \(mc)…", pct: nil))
        let launchTarget: String
        switch loader {
        case .vanilla: launchTarget = try await Provisioner.downloadVanilla(spec, dir: dir, progress: progress)
        case .fabric: launchTarget = try await Provisioner.downloadFabric(spec, dir: dir, progress: progress)
        default: launchTarget = try await Provisioner.runInstaller(spec, dir: dir, java: java, progress: progress)
        }
        try "# Accepted via OMNIServers — https://aka.ms/MinecraftEULA\neula=true\n"
            .write(to: dir.appending(path: "eula.txt"), atomically: true, encoding: .utf8)

        let wanted = index.files.filter(serverWants)
        for (i, f) in wanted.enumerated() {
            guard safeRelativePath(f.path) else { continue }
            guard let src = f.downloads.lazy.compactMap(downloadAllowed).first else {
                throw ProvisionError.message("\(f.path): download host isn't allowed by the modpack format.")
            }
            guard f.hashes.sha1 != nil || f.hashes.sha512 != nil else {
                throw ProvisionError.message("\(f.path): no checksum in the pack — refusing to install it.")
            }
            let out = dir.appending(path: f.path)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            progress(ProvisionProgress(stage: "mods", message: "Installing mods… \(i + 1)/\(wanted.count)",
                                       pct: (i + 1) * 100 / max(1, wanted.count)))
            try await Provisioner.downloadTo(src.absoluteString, dest: out, label: f.path) { _ in }
            if let want = f.hashes.sha1, try Provisioner.sha1Hex(out) != want {
                throw ProvisionError.message("\(f.path): checksum mismatch — the download may be corrupted, try again.")
            }
        }

        progress(ProvisionProgress(stage: "overrides", message: "Applying the pack's configs…", pct: nil))
        for prefix in ["overrides", "server-overrides"] { // server-overrides wins: applied second
            let out = scratch.appending(path: "x-\(prefix)")
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            _ = try Subprocess.run("/usr/bin/unzip", ["-o", "-q", archive.path, "\(prefix)/*", "-d", out.path], timeout: 300)
            try mergeRegularFiles(from: out.appending(path: prefix), into: dir)
        }

        let bedrock = false
        try await Provisioner.firstBoot(spec, dir: dir, java: java, launchTarget: launchTarget, serverType: loader.serverType, progress: progress)
        Provisioner.applyStartingSettings(dir: dir, bedrock: bedrock, port: Provisioner.pickFreePort(taken: takenPorts),
                                          seed: nil, gamemode: nil, difficulty: nil, motd: nil, maxPlayers: nil)
        return Created(serverType: loader.serverType, launchTarget: launchTarget, mcVersion: mc, dir: dir, javaPath: java)
    }

    /// Copy regular files and directories only; symlinks are skipped.
    static func mergeRegularFiles(from src: URL, into dst: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: src.path) else { return }
        while let rel = e.nextObject() as? String {
            let type = e.fileAttributes?[.type] as? FileAttributeType
            if type == .typeSymbolicLink { e.skipDescendants(); continue }
            guard safeRelativePath(rel) else { e.skipDescendants(); continue }
            let item = src.appending(path: rel), target = dst.appending(path: rel)
            if type == .typeDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if type == .typeRegular {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) } // our own fresh folder
                try fm.copyItem(at: item, to: target)
            }
        }
    }
}
