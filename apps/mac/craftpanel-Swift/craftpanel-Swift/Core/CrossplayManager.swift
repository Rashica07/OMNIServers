import Foundation
import CryptoKit

/// Bedrock cross-play: one-click Geyser + Floodgate so players on the
/// Bedrock edition (phone / console / Windows 10 store) can join a Java
/// server, no Java account needed. Downloads from GeyserMC's own build
/// API. Direct port of `crossplay.rs`.
///
/// `crossplay_forward` (UPnP) is deliberately not ported here, same
/// documented decision as `NetworkInfo`'s own UPnP skip — it's the exact
/// same underlying `net::upnp_forward_port` call on the Rust side.
nonisolated struct CrossplayStatus: Sendable, Equatable {
    /// this loader can run Geyser as a plugin/mod
    var compatible: Bool
    var geyser: Bool
    var floodgate: Bool
    /// UDP port Bedrock players connect on
    var bedrockPort: UInt16
    /// where the jars go: "plugins" or "mods"
    var folder: String
    /// Geyser build OMNIServers installed (nil = unknown, e.g. installed by hand or before this was tracked)
    var geyserBuild: Int? = nil
    /// `bedrock.transport` from Geyser's config, if set
    var transport: String? = nil
    /// `bedrock.clone-remote-port: true` can't use Geyser's built-in sign-in
    var cloneRemotePort: Bool = false

    /// Geyser older than build 1273 can't speak NetherNet (Bedrock 26.60).
    var needsUpdate: Bool { BedrockNetwork.geyserNeedsUpdate(geyserInstalled: geyser, installedBuild: geyserBuild) }
}

nonisolated enum CrossplayManager {
    private static let geyserAPI = "https://download.geysermc.org/v2/projects"
    private static let defaultBedrockPort: UInt16 = 19132

    /// GeyserMC artifact name for this loader.
    static func platform(_ t: ServerType) -> String? {
        switch t {
        case .paper, .spigot: "spigot"
        case .fabric: "fabric"
        case .neoforge: "neoforge"
        // Geyser has no (Lex) Forge build.
        case .forge: nil
        // Vanilla has no plugin loader to install Geyser into. A native
        // Bedrock server already speaks Bedrock, so this doesn't apply.
        case .vanilla, .bedrock, .fivem, .terraria, .omnihost: nil
        }
    }

    static func folder(_ t: ServerType) -> String {
        (t == .paper || t == .spigot) ? "plugins" : "mods"
    }

    private static func jars(_ dir: URL, _ t: ServerType) -> [String] {
        var out: [String] = []
        for sub in [folder(t), "mods", "plugins", "mods-disabled"] {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: sub).path)) ?? []
            for name in entries {
                let n = name.lowercased()
                if n.hasSuffix(".jar") { out.append(n) }
            }
        }
        return out
    }

    private static let configBases = ["plugins/Geyser-Spigot", "config/Geyser-Fabric", "config/geyser-neoforge"]

    /// Geyser writes `config/Geyser-*/config.yml`; only the `bedrock:` section's own keys count.
    private static func readConfig(_ dir: URL) -> (port: Int?, transport: String?, clone: Bool) {
        for base in configBases {
            let cfg = dir.appending(path: base).appending(path: "config.yml")
            guard let text = try? String(contentsOf: cfg, encoding: .utf8) else { continue }
            return BedrockNetwork.readBedrockSection(text.components(separatedBy: "\n"))
        }
        return (nil, nil, false)
    }

    private static func bedrockPort(_ dir: URL) -> UInt16 {
        if let p = readConfig(dir).port, (1...65535).contains(p) { return UInt16(p) }
        return defaultBedrockPort
    }

    // MARK: which Geyser build is installed (OMNIServers records it; the jar name doesn't say)

    static let buildFile = ".craftpanel-geyser.json"

    static func installedBuild(_ dir: URL) -> Int? {
        guard let data = try? Data(contentsOf: dir.appending(path: buildFile)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["build"] as? Int
    }

    private static func recordBuild(_ dir: URL, build: Int, version: String) {
        let obj: [String: Any] = ["build": build, "version": version]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: dir.appending(path: buildFile)) }
    }

    /// JVM args to launch this server with: the user's own plus Geyser's NetherNet flag when it applies.
    static func launchJvmArgs(serverDir: URL, serverType: ServerType, userArgs: String?) -> String? {
        guard platform(serverType) != nil else { return userArgs }
        let geyser = jars(serverDir, serverType).contains { $0.contains("geyser") }
        return BedrockNetwork.withGeyserFlags(userArgs, geyserInstalled: geyser, configTransport: readConfig(serverDir).transport)
    }

    static func status(serverDir: URL, serverType: ServerType) -> CrossplayStatus {
        let js = jars(serverDir, serverType)
        let geyser = js.contains { $0.contains("geyser") }
        let cfg = readConfig(serverDir)
        return CrossplayStatus(
            compatible: platform(serverType) != nil,
            geyser: geyser,
            floodgate: js.contains { $0.contains("floodgate") },
            bedrockPort: bedrockPort(serverDir),
            folder: folder(serverType),
            geyserBuild: geyser ? installedBuild(serverDir) : nil,
            transport: cfg.transport,
            cloneRemotePort: cfg.clone
        )
    }

    /// Network fetch; tests replace it.
    nonisolated(unsafe) static var fetch: @Sendable (URLRequest) async throws -> Data = { request in
        try await URLSession.shared.data(for: request).0
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("CraftPanel", forHTTPHeaderField: "User-Agent")
        return try await fetch(request)
    }

    /// Downloads the newest build of a GeyserMC project's artifact, SHA-256 checked, into `dest`. Returns the build.
    @discardableResult
    private static func download(project: String, artifact: String, dest: URL, name: String) async throws -> (build: Int, version: String) {
        guard let infoURL = URL(string: "\(geyserAPI)/\(project)/versions/latest/builds/latest") else {
            throw RconServiceError.message("bad download URL")
        }
        let info: [String: Any]
        do {
            info = (try JSONSerialization.jsonObject(with: try await get(infoURL)) as? [String: Any]) ?? [:]
        } catch {
            throw RconServiceError.message("\(project) download failed: \(error.localizedDescription)")
        }
        guard let version = info["version"] as? String, let build = info["build"] as? Int,
              let file = (info["downloads"] as? [String: Any])?[artifact] as? [String: Any],
              let url = URL(string: "\(geyserAPI)/\(project)/versions/\(version)/builds/\(build)/downloads/\(artifact)")
        else { throw RconServiceError.message("\(project) has no \(artifact) build right now.") }
        let data: Data
        do { data = try await get(url) } catch {
            throw RconServiceError.message("\(project) download failed: \(error.localizedDescription)")
        }
        guard data.count >= 100_000 else {
            throw RconServiceError.message("\(project) download looks wrong (\(data.count) bytes)")
        }
        if let sha = file["sha256"] as? String {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(sha) == .orderedSame else {
                throw RconServiceError.message("\(name) didn't match the checksum GeyserMC published, so OMNIServers did not install it. Try again.")
            }
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try data.write(to: dest.appending(path: name))
        return (build, version)
    }

    /// Replaces an old Geyser with the newest build (old jar goes to the server's trash folder; Floodgate stays).
    /// Needed for Bedrock 26.60: only Geyser build 1273 and newer speak NetherNet.
    static func updateGeyser(serverDir: URL, serverType: ServerType) async throws -> CrossplayStatus {
        guard let artifact = platform(serverType) else {
            throw RconServiceError.message("This server type can't run Geyser.")
        }
        let fm = FileManager.default
        let trash = serverDir.appending(path: ".craftpanel-trash")
        let staging = trash.appending(path: "geyser-update-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        // download first, so a failed download leaves the old Geyser in place
        let got = try await download(project: "geyser", artifact: artifact, dest: staging, name: "Geyser-\(artifact).jar")
        for sub in Set([folder(serverType), "mods", "plugins", "mods-disabled"]) {
            let dir = serverDir.appending(path: sub)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.lowercased().hasSuffix(".jar") && name.lowercased().contains("geyser") {
                let dest = trash.appending(path: "\(UUID().uuidString.prefix(6))-\(name)")
                _ = try? fm.moveItem(at: dir.appending(path: name), to: dest)
            }
        }
        let destDir = serverDir.appending(path: folder(serverType))
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] {
            let target = destDir.appending(path: name)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: staging.appending(path: name), to: target)
        }
        try? fm.removeItem(at: staging)
        recordBuild(serverDir, build: got.build, version: got.version)
        return status(serverDir: serverDir, serverType: serverType)
    }

    static func enable(serverDir: URL, serverType: ServerType, mcVersion: String? = nil) async throws -> CrossplayStatus {
        guard let artifact = platform(serverType) else {
            throw RconServiceError.message("Bedrock cross-play needs Paper, Spigot, Fabric or NeoForge — vanilla/Forge can't run Geyser.")
        }
        let dest = serverDir.appending(path: folder(serverType))

        let got = try await download(project: "geyser", artifact: artifact, dest: dest, name: "Geyser-\(artifact).jar")
        recordBuild(serverDir, build: got.build, version: got.version)
        // Floodgate isn't published for the "spigot" artifact on every
        // channel; try, but don't fail the whole thing if only Geyser lands.
        var floodgateError: Error?
        do {
            if artifact == "spigot" {
                try await download(project: "floodgate", artifact: artifact, dest: dest, name: "floodgate-\(artifact).jar")
            } else {
                // GeyserMC's own download API has no Fabric/NeoForge Floodgate; Modrinth does.
                _ = try await ModrinthClient.install(serverDir: serverDir, serverType: serverType, projectID: "floodgate",
                                                     projectType: "mod", mcVersion: mcVersion)
            }
        } catch {
            floodgateError = error
        }

        // Fabric Geyser needs the Fabric API.
        if serverType == .fabric {
            _ = try? await ModrinthClient.install(
                serverDir: serverDir, serverType: serverType, projectID: "fabric-api",
                projectType: "mod", mcVersion: nil
            )
        }

        var st = status(serverDir: serverDir, serverType: serverType)
        if let floodgateError, !st.floodgate {
            throw RconServiceError.message(
                "Geyser installed. Floodgate couldn't be fetched automatically (\(floodgateError.localizedDescription)). Grab it from geysermc.org and drop it in \(st.folder)/."
            )
        }
        st = status(serverDir: serverDir, serverType: serverType)
        return st
    }

    static func disable(serverDir: URL, serverType: ServerType) {
        try? FileManager.default.removeItem(at: serverDir.appending(path: buildFile))
        // Floodgate installed from Modrinth is tracked in the add-on list: remove it there so a later "turn on" reinstalls it.
        for e in ModrinthClient.installed(serverDir: serverDir) where e.slug == "floodgate" {
            try? ModrinthClient.removeOne(serverDir: serverDir, serverType: serverType, projectID: e.projectID)
        }
        let fm = FileManager.default
        let trash = serverDir.appending(path: ".craftpanel-trash")
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        for sub in [folder(serverType), "mods", "plugins"] {
            let dir = serverDir.appending(path: sub)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                let n = name.lowercased()
                if n.hasSuffix(".jar"), n.contains("geyser") || n.contains("floodgate") {
                    _ = try? fm.moveItem(at: dir.appending(path: name), to: trash.appending(path: name))
                }
            }
        }
    }
}
