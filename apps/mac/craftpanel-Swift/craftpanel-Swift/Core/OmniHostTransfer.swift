import Foundation
import CryptoKit

/// Moves a Java server onto OMNIHost: a COPY of its world (the engine converts the copy to its own
/// format, one way), its settings, player lists and icon. The Java server is never touched, so it
/// stays as the backup and the way back. Mods and plugins do not move: they don't run on OMNIHost.
nonisolated enum OmniHostTransfer {
    struct Plan: Equatable, Sendable {
        var name: String
        var sourceDir: URL
        var levelName: String
        var worldBytes: Int64
        var settings: PumpkinConfig.Settings
        var modCount: Int
        var pluginCount: Int
        var hasIcon: Bool
        /// Player lists with something in them (`ops.json`, `whitelist.json`, ...).
        var lists: [String]
        /// Players whose saved data (inventory, position, stats, advancements) moves with the world.
        var playerCount: Int = 0
        var mods: ModReport = ModReport()
    }

    /// What each mod in `mods/` means for OMNIHost. None of them run there; this says why.
    struct ModReport: Equatable, Sendable {
        /// Client-only mods: they belong in the player's launcher, not on a server.
        var clientOnly: [String] = []
        /// Server speed-ups (Lithium, FerriteCore ...): the engine is already fast, nothing to port.
        var notNeeded: [String] = []
        /// Mods that add gameplay: they stay on the Java server.
        var gameplay: [String] = []
        var total: Int { clientOnly.count + notNeeded.count + gameplay.count }
    }

    enum TransferError: LocalizedError {
        case notJava, noWorld, notEnoughSpace(needed: Int64, free: Int64), destinationExists(String), copyFailed(String)
        var errorDescription: String? {
            switch self {
            case .notJava: "Only Java servers can be moved to OMNIHost."
            case .noWorld: "No world found in this server yet (no level.dat). Start the Java server once so it creates one, then try again."
            case .notEnoughSpace(let n, let f): "Not enough free space: the copy needs about \(format(n)) and \(format(f)) is free."
            case .destinationExists(let p): "A folder named \"\(p)\" already exists. Pick another name."
            case .copyFailed(let m): "Copying the world failed: \(m)"
            }
        }
    }

    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func canTransfer(_ type: ServerType) -> Bool { type.usesJava }

    /// Player lists the engine reads from `data/` (same file names and format as vanilla, checked).
    static let listFiles = ["ops.json", "whitelist.json", "banned-players.json", "banned-ips.json"]
    /// Inside the world folder: mod-only data and the lock, left behind.
    static let skippedInWorld = ["session.lock", "vss-lod"]

    /// `server.properties` -> the settings the engine understands.
    static func settings(from props: Properties) -> PumpkinConfig.Settings {
        func int(_ k: String) -> Int? { props.get(k).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func bool(_ k: String) -> Bool { props.get(k)?.trimmingCharacters(in: .whitespaces).lowercased() == "true" }
        var level = (props.get("level-name") ?? "world").trimmingCharacters(in: .whitespaces)
        if level.isEmpty || level.contains("/") || level.contains("..") || level.hasPrefix(".") { level = "world" }
        var port: UInt16 = 25565
        if let raw = props.get("server-port"), let p = UInt16(raw.trimmingCharacters(in: .whitespaces)), p != 0 { port = p }
        return PumpkinConfig.Settings(
            motd: props.get("motd") ?? "",
            port: port,
            maxPlayers: int("max-players") ?? 20,
            gamemode: (props.get("gamemode") ?? "survival").lowercased(),
            difficulty: (props.get("difficulty") ?? "normal").lowercased(),
            seed: props.get("level-seed") ?? "",
            onlineMode: props.get("online-mode")?.trimmingCharacters(in: .whitespaces).lowercased() != "false",
            levelName: level,
            viewDistance: int("view-distance"),
            simulationDistance: int("simulation-distance"),
            whitelist: bool("white-list"),
            enforceWhitelist: bool("enforce-whitelist"),
            hardcore: bool("hardcore"),
            allowNether: props.get("allow-nether")?.trimmingCharacters(in: .whitespaces).lowercased() != "false",
            spawnProtection: int("spawn-protection") ?? 16,
            forceGamemode: bool("force-gamemode"),
            opPermissionLevel: int("op-permission-level") ?? 4,
            pvp: props.get("pvp")?.trimmingCharacters(in: .whitespaces).lowercased() != "false",
            resourcePackURL: props.get("resource-pack") ?? "",
            resourcePackSHA1: props.get("resource-pack-sha1") ?? "",
            resourcePackForce: bool("require-resource-pack"),
            resourcePackPrompt: props.get("resource-pack-prompt") ?? "")
    }

    // MARK: Players

    /// The id this engine gives an offline-mode player: the first 16 bytes of SHA-256 of the name.
    /// (Java uses an MD5 based id, so offline players need their files renamed. Checked against the real engine.)
    static func offlineUUID(name: String) -> String {
        let h = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        let hex = h.map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        func part(_ a: Int, _ b: Int) -> String { String(c[a..<b]) }
        return [part(0, 8), part(8, 12), part(12, 16), part(16, 20), part(20, 32)].joined(separator: "-")
    }

    /// id -> name from the files a Java server keeps (usercache, whitelist, ops, bans).
    static func knownPlayers(in dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        for f in ["usercache.json", "whitelist.json", "ops.json", "banned-players.json"] {
            guard let d = FileManager.default.contents(atPath: dir.appending(path: f).path),
                  let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { continue }
            for e in arr {
                if let u = e["uuid"] as? String, let n = e["name"] as? String, !n.isEmpty { out[u.lowercased()] = n }
            }
        }
        return out
    }

    /// Saved player data files (`world/players/data/<uuid>.dat`).
    static func playerIDs(world: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: world.appending(path: "players/data").path)) ?? []
        return names.filter { $0.hasSuffix(".dat") }.map { String($0.dropLast(4)).lowercased() }.sorted()
    }

    /// Java's advancement file -> the engine's. `{"adv": {"criteria": {"c": "2026-08-29 17:40:46 +0200"}, "done": true}}`
    /// becomes `{"adv": {"c": {"secs_since_epoch": ..., "nanos_since_epoch": 0}}}`. nil if it can't be read.
    static func convertAdvancements(_ data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var out: [String: Any] = [:]
        for (adv, v) in root {
            guard let entry = v as? [String: Any], let criteria = entry["criteria"] as? [String: Any] else { continue }
            var c: [String: Any] = [:]
            for (name, t) in criteria {
                guard let str = t as? String, let date = fmt.date(from: str) else { continue }
                c[name] = ["secs_since_epoch": Int(date.timeIntervalSince1970), "nanos_since_epoch": 0]
            }
            out[adv] = c
        }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// Rewrites `uuid` fields of a player list with `map` (old id -> new id).
    static func remapList(_ data: Data, map: [String: String]) -> Data? {
        guard var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for i in arr.indices {
            if let u = arr[i]["uuid"] as? String, let n = map[u.lowercased()] { arr[i]["uuid"] = n }
        }
        return try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
    }

    /// Moves each player's data over to the new engine: offline servers get their ids renamed, and
    /// advancements are converted. Returns how many players were carried.
    @discardableResult
    static func carryPlayers(sourceDir: URL, world: URL, dataDir: URL, onlineMode: Bool) -> Int {
        let fm = FileManager.default
        let names = knownPlayers(in: sourceDir)
        var map: [String: String] = [:]
        for id in playerIDs(world: world) {
            if onlineMode { map[id] = id }
            else if let n = names[id] { map[id] = offlineUUID(name: n) }
        }
        var carried = 0
        let base = world.appending(path: "players")
        for (old, new) in map {
            if old != new {
                for ext in ["dat", "dat_old"] {
                    let a = base.appending(path: "data/\(old).\(ext)"), b = base.appending(path: "data/\(new).\(ext)")
                    if fm.fileExists(atPath: a.path) { try? fm.removeItem(at: b); try? fm.moveItem(at: a, to: b) }
                }
                let sa = base.appending(path: "stats/\(old).json"), sb = base.appending(path: "stats/\(new).json")
                if fm.fileExists(atPath: sa.path) { try? fm.removeItem(at: sb); try? fm.moveItem(at: sa, to: sb) }
            }
            // Advancements always need converting; the engine rejects the Java layout.
            let aa = base.appending(path: "advancements/\(old).json"), ab = base.appending(path: "advancements/\(new).json")
            if let d = fm.contents(atPath: aa.path) {
                try? fm.removeItem(at: aa)
                if let converted = convertAdvancements(d) { try? converted.write(to: ab) }
            }
            carried += 1
        }
        // Advancements/stats of players we can't map (offline, unknown name) would only confuse the engine.
        for sub in ["advancements", "stats"] {
            let dir = base.appending(path: sub)
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
                let id = String(f.dropLast(5)).lowercased()
                if !map.values.contains(id) { try? fm.removeItem(at: dir.appending(path: f)) }
            }
        }
        // Lists: ids follow the same map.
        for f in listFiles {
            let url = dataDir.appending(path: f)
            if let d = fm.contents(atPath: url.path), let r = remapList(d, map: map) { try? r.write(to: url) }
        }
        // Players on the lists who never had a data file still need their new id (offline only).
        if !onlineMode {
            for f in listFiles {
                let url = dataDir.appending(path: f)
                guard let d = fm.contents(atPath: url.path), var arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { continue }
                for i in arr.indices {
                    if let n = arr[i]["name"] as? String, !n.isEmpty, let u = arr[i]["uuid"] as? String, map[u.lowercased()] == nil,
                       u.lowercased() != offlineUUID(name: n) { arr[i]["uuid"] = offlineUUID(name: n) }
                }
                if let r = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys]) { try? r.write(to: url) }
            }
        }
        return carried
    }

    // MARK: Mods

    /// Mod ids that only make a Java server faster. OMNIHost doesn't need them.
    static let performanceMods: Set<String> = [
        "lithium", "ferritecore", "c2me", "c2me-fabric", "krypton", "noisium", "servercore", "starlight",
        "modernfix", "vmp", "vmp-fabric", "scalablelux", "moonrise", "spark", "memoryleakfix", "fastback",
        "chunky", "no-chat-reports", "badoptimizations", "dimthread", "async",
    ]

    /// Sorts the jars in `mods/` by what they are, from each jar's `fabric.mod.json`.
    static func classifyMods(in dir: URL) -> ModReport {
        let fm = FileManager.default
        let folder = dir.appending(path: "mods")
        var report = ModReport()
        for jar in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter({ $0.hasSuffix(".jar") }).sorted() {
            let path = folder.appending(path: jar).path
            guard let r = try? Subprocess.run("/usr/bin/unzip", ["-p", path, "fabric.mod.json"], timeout: 10), r.status == 0,
                  let json = try? JSONSerialization.jsonObject(with: Data(r.stdoutString.utf8)) as? [String: Any] else {
                report.gameplay.append(jar.replacingOccurrences(of: ".jar", with: "")); continue
            }
            let id = (json["id"] as? String ?? "").lowercased()
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? jar.replacingOccurrences(of: ".jar", with: "")
            let env = (json["environment"] as? String) ?? "*"
            if id.hasPrefix("fabric-") || id == "fabricloader" || id == "fabric-api" || id == "java" || id == "minecraft" { continue }   // libraries
            if env == "client" { report.clientOnly.append(name) }
            else if performanceMods.contains(id) { report.notNeeded.append(name) }
            else { report.gameplay.append(name) }
        }
        return report
    }

    static func plan(sourceDir: URL, name: String) throws -> Plan {
        let props = Properties.load(dir: sourceDir)
        let s = settings(from: props)
        let fm = FileManager.default
        let world = sourceDir.appending(path: s.levelName, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: world.appending(path: "level.dat").path) else { throw TransferError.noWorld }
        func jars(_ folder: String) -> Int {
            ((try? fm.contentsOfDirectory(atPath: sourceDir.appending(path: folder).path)) ?? []).filter { $0.hasSuffix(".jar") }.count
        }
        let lists = listFiles.filter { f in
            guard let d = fm.contents(atPath: sourceDir.appending(path: f).path),
                  let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return false }
            return !arr.isEmpty
        }
        return Plan(name: name, sourceDir: sourceDir, levelName: s.levelName, worldBytes: size(of: world),
                    settings: s, modCount: jars("mods"), pluginCount: jars("plugins"),
                    hasIcon: BrandingManager.hasIcon(serverDir: sourceDir), lists: lists,
                    playerCount: playerIDs(world: world).count, mods: classifyMods(in: sourceDir))
    }

    /// Bytes on disk under `dir`, not counting what `skippedInWorld` leaves behind.
    static func size(of dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            if skippedInWorld.contains(url.lastPathComponent) { en.skipDescendants(); continue }
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// The engine rewrites the copy in its own format (about a third bigger in a real test),
    /// so ask for room for that, plus a little for the engine's own files.
    static func requiredFreeBytes(_ plan: Plan) -> Int64 { plan.worldBytes * 3 / 2 + 100_000_000 }

    static func freeBytes(at dir: URL) -> Int64 {
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    /// One sentence for the popup about mods and plugins.
    static func leftBehindSummary(_ plan: Plan) -> String {
        let m = plan.mods
        func n(_ c: Int, _ one: String, _ many: String) -> String { c == 1 ? "1 \(one)" : "\(c) \(many)" }
        var parts: [String] = []
        if !m.gameplay.isEmpty { parts.append("\(n(m.gameplay.count, "gameplay mod stays", "gameplay mods stay")) on the Java server (they don't run on OMNIHost, so blocks, biomes or items they added may be lost or look wrong)") }
        if !m.notNeeded.isEmpty { parts.append(n(m.notNeeded.count, "speed-up mod isn't", "speed-up mods aren't") + " needed") }
        if !m.clientOnly.isEmpty { parts.append(n(m.clientOnly.count, "client-only mod belongs", "client-only mods belong") + " in your launcher") }
        if plan.pluginCount > 0 { parts.append(n(plan.pluginCount, "plugin stays", "plugins stay") + " behind") }
        if parts.isEmpty { parts.append("\(plan.modCount) mod file(s) stay behind") }
        return parts.joined(separator: "; ") + ". A list is saved in the new server folder."
    }

    /// A plain-text note saved next to the new server: what came along and what stayed on the Java server.
    static func report(_ plan: Plan) -> String {
        var l = ["Moved from the Java server \"\(plan.name)\" to OMNIHost.", "",
                 "Came along: world, \(plan.playerCount) player(s) with inventory, position, stats and advancements, whitelist, ops, bans, settings, icon."]
        if !plan.mods.clientOnly.isEmpty { l += ["", "Client-only mods (install these in your launcher, not on the server):"] + plan.mods.clientOnly.map { "  - \($0)" } }
        if !plan.mods.notNeeded.isEmpty { l += ["", "Speed-up mods (OMNIHost is already fast, not needed):"] + plan.mods.notNeeded.map { "  - \($0)" } }
        if !plan.mods.gameplay.isEmpty { l += ["", "Mods that stay on the Java server (they do not run on OMNIHost):"] + plan.mods.gameplay.map { "  - \($0)" } }
        if plan.pluginCount > 0 { l += ["", "\(plan.pluginCount) plugin(s) stay on the Java server."] }
        return l.joined(separator: "\n") + "\n"
    }

    /// Builds the OMNIHost server folder at `dest`. Removes it again if anything fails.
    static func perform(_ plan: Plan, to dest: URL, free: Int64? = nil,
                        progress: @Sendable (String) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path) == false else { throw TransferError.destinationExists(dest.lastPathComponent) }
        let available = free ?? freeBytes(at: dest.deletingLastPathComponent())
        let needed = requiredFreeBytes(plan)
        guard available >= needed else { throw TransferError.notEnoughSpace(needed: needed, free: available) }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            progress("Copying the world (\(format(plan.worldBytes)))…")
            let src = plan.sourceDir.appending(path: plan.levelName, directoryHint: .isDirectory)
            let target = dest.appending(path: plan.levelName, directoryHint: .isDirectory)
            // -c: clone on APFS, so the copy is instant and takes no space until the engine rewrites it.
            let r = try await Subprocess.runAsync("/bin/cp", ["-Rc", src.path, target.path], timeout: 3600)
            guard r.status == 0 else { throw TransferError.copyFailed(r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)) }
            for skip in skippedInWorld { try? fm.removeItem(at: target.appending(path: skip)) }

            progress("Copying player lists…")
            let data = dest.appending(path: "data", directoryHint: .isDirectory)
            try fm.createDirectory(at: data, withIntermediateDirectories: true)
            for f in plan.lists { try fm.copyItem(at: plan.sourceDir.appending(path: f), to: data.appending(path: f)) }

            progress("Moving players (inventory, position, advancements)…")
            carryPlayers(sourceDir: plan.sourceDir, world: target, dataDir: data, onlineMode: plan.settings.onlineMode)

            progress("Writing settings…")
            if plan.hasIcon {
                try fm.copyItem(at: plan.sourceDir.appending(path: BrandingManager.iconFile), to: dest.appending(path: BrandingManager.iconFile))
            } else {
                BrandingManager.installOmniHostIcon(serverDir: dest)
            }
            try report(plan).write(to: dest.appending(path: "OMNIHost-transfer.txt"), atomically: true, encoding: .utf8)
            try PumpkinConfig.render(plan.settings).write(to: dest.appending(path: PumpkinConfig.fileName), atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }
}
