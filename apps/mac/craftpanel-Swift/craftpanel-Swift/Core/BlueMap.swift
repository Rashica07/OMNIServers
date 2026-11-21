import Foundation

/// Live map via BlueMap (MIT, Modrinth `bluemap`): a 3D/flat web map of
/// every dimension with live player markers, served by the server itself.
/// OMNIServers installs it, writes its config (the texture-download
/// consent you give in the Map tab, and a port that doesn't clash with
/// other servers' maps), and shows the map in-app.
nonisolated enum BlueMap {
    static let projectID = "bluemap"
    static let defaultPort = 8100

    /// Vanilla can't load plugins/mods; Bedrock has no Java map at all.
    static func supported(_ type: ServerType) -> Bool {
        !type.isBedrock && type != .vanilla
    }

    static func configDir(_ dir: URL, type: ServerType) -> URL {
        type == .paper || type == .spigot ? dir.appending(path: "plugins/BlueMap") : dir.appending(path: "config/bluemap")
    }

    static func isInstalled(_ dir: URL, type: ServerType) -> Bool {
        let folder = ModrinthClient.contentDir(dir, serverType: type, projectType: "mod")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.lowercased().hasPrefix("bluemap") && $0.lowercased().hasSuffix(".jar") }
    }

    /// The port from webserver.conf, or BlueMap's default.
    static func port(_ dir: URL, type: ServerType) -> Int {
        let text = (try? String(contentsOf: configDir(dir, type: type).appending(path: "webserver.conf"), encoding: .utf8)) ?? ""
        return parsePort(text) ?? defaultPort
    }

    static func parsePort(_ conf: String) -> Int? {
        for line in conf.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("port:") else { continue }
            return Int(t.dropFirst(5).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func consentGiven(_ dir: URL, type: ServerType) -> Bool {
        let text = (try? String(contentsOf: configDir(dir, type: type).appending(path: "core.conf"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "") == "accept-download:true" }
    }

    /// First free port from 8100 that no other server's map uses.
    static func pickPort(otherServers: [(dir: URL, type: ServerType)]) -> Int {
        let taken = Set(otherServers.filter { isInstalled($0.dir, type: $0.type) }.map { port($0.dir, type: $0.type) })
        var p = defaultPort
        while taken.contains(p) || !Doctor.portFree(UInt16(p)) { p += 1 }
        return p
    }

    /// Sets `accept-download: true` (the user just agreed in the Map tab)
    /// and the web port. Edits BlueMap's own files if they exist, keeping
    /// every other setting and comment; otherwise writes minimal ones —
    /// BlueMap fills in defaults for anything missing.
    static func configure(_ dir: URL, type: ServerType, port: Int) throws {
        let cfg = configDir(dir, type: type)
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try upsert(cfg.appending(path: "core.conf"), key: "accept-download", value: "true")
        try upsert(cfg.appending(path: "webserver.conf"), key: "port", value: String(port))
    }

    /// Replaces the first top-level `key: …` line, or appends one.
    static func upsert(_ file: URL, key: String, value: String) throws {
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) {
            lines[i] = "\(key): \(value)"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("\(key): \(value)")
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func install(_ dir: URL, type: ServerType, mcVersion: String?, port: Int) async throws {
        _ = try await ModrinthClient.install(serverDir: dir, serverType: type, projectID: projectID, projectType: "mod", mcVersion: mcVersion)
        try configure(dir, type: type, port: port)
    }

    static func localURL(port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// Is the map page actually being served? A bare 404 means the web
    /// server is up but BlueMap hasn't unpacked its web app yet.
    static func isUp(port: Int) async -> Bool {
        var req = URLRequest(url: localURL(port: port))
        req.timeoutInterval = 1.5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
