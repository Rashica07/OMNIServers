import Foundation

/// Anti-cheat: (1) advisor — know the common anti-cheats per loader, spot
/// when a reachable server has none; (2) suspicion — cheap signals
/// scraped from the logs (movement kicks, flight, anti-cheat plugin
/// flags, rapid re-joins). Direct port of `anticheat.rs`.
///
/// Advisory only. Never touches `online-mode`.
nonisolated struct AntiCheatRecommendation: Sendable, Identifiable {
    var id: String { name }
    var name: String
    /// Modrinth slug for one-click install via the Add-ons tab.
    var slug: String
    var blurb: String
}

nonisolated struct AntiCheatAdvice: Sendable {
    /// anti-cheats detected in mods/ or plugins/
    var installed: [String] = []
    var recommended: [AntiCheatRecommendation] = []
    /// the server's port is reachable from this machine (≈ exposed)
    var isPublic: Bool = false
    /// public + no anti-cheat installed
    var warn: Bool = false
    var supported: Bool = false
}

nonisolated struct Suspicion: Sendable, Identifiable {
    var id: String { name }
    var name: String
    var flags: Int
    var rejoins: Int
    /// a few example log lines
    var samples: [String]
}

nonisolated enum AntiCheat {
    private struct Entry {
        let name: String
        let fragments: [String]
        let slug: String
        let blurb: String
    }

    private static func catalogue(_ type: ServerType) -> [Entry] {
        switch type {
        case .paper, .spigot:
            return [
                Entry(name: "GrimAC", fragments: ["grim"], slug: "grimac", blurb: "Modern, low-false-positive. The usual pick for Paper."),
                Entry(name: "Vulcan", fragments: ["vulcan"], slug: "", blurb: "Paid, very thorough (not on Modrinth)."),
                Entry(name: "NoCheatPlus", fragments: ["nocheatplus", "ncp"], slug: "", blurb: "Classic, free, still maintained forks."),
                Entry(name: "Spartan", fragments: ["spartan"], slug: "", blurb: "Paid, plug-and-play."),
            ]
        case .fabric, .forge, .neoforge:
            return [
                Entry(name: "Vulcan (Fabric)", fragments: ["vulcan"], slug: "", blurb: "Server-side checks for Fabric."),
                Entry(name: "PandaAntiCheat", fragments: ["panda", "pandaanticheat"], slug: "", blurb: "Lightweight Fabric anti-cheat."),
                Entry(name: "NoCheatPlus (Fabric)", fragments: ["nocheat"], slug: "", blurb: "Fabric port."),
            ]
        // Vanilla has no plugin/mod loader to install an anti-cheat into;
        // Bedrock has no Modrinth mod ecosystem in this sense at all.
        case .vanilla, .bedrock, .fivem, .terraria, .omnihost:
            return []
        }
    }

    private static func listJars(_ dir: URL) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for sub in ["mods", "mods-disabled", "plugins"] {
            if let names = try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path) {
                out.append(contentsOf: names.map { $0.lowercased() }.filter { $0.hasSuffix(".jar") })
            }
        }
        return out
    }

    static func advise(serverDir: URL, serverType: ServerType, isPublic: Bool) -> AntiCheatAdvice {
        let jars = listJars(serverDir)
        let catalog = catalogue(serverType)

        let installed = catalog
            .filter { entry in entry.fragments.contains { f in jars.contains { $0.contains(f) } } }
            .map(\.name)

        let recommended: [AntiCheatRecommendation] = installed.isEmpty
            ? catalog.filter { !$0.slug.isEmpty }.map { AntiCheatRecommendation(name: $0.name, slug: $0.slug, blurb: $0.blurb) }
            : []

        return AntiCheatAdvice(
            installed: installed,
            recommended: recommended,
            isPublic: isPublic,
            warn: isPublic && installed.isEmpty && serverType != .vanilla,
            supported: serverType != .vanilla
        )
    }

    // MARK: - Suspicion from logs

    private static func recentLogText(_ dir: URL) -> String {
        let logsDir = dir.appendingPathComponent("logs")
        var text = ""
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: logsDir.path) {
            let gz = names.filter { $0.hasSuffix(".log.gz") }.sorted()
            for name in gz.suffix(4) {
                if let decoded = gunzip(logsDir.appendingPathComponent(name)) {
                    text += decoded
                }
            }
        }
        if let latest = try? String(contentsOf: logsDir.appendingPathComponent("latest.log"), encoding: .utf8) {
            text += latest
        }
        return text
    }

    private static func gunzip(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return Gzip.decompress(data).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func isValidName(_ n: Substring) -> Bool {
        !n.isEmpty && n.count <= 16 && n.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func suspicion(serverDir: URL) -> [Suspicion] {
        let text = recentLogText(serverDir)
        var byName: [String: Suspicion] = [:]
        var lastJoin: [String: Int] = [:]

        let flagMarkers = ["moved too quickly", "moved wrongly", "floating too long", "flying is not enabled", "was kicked for"]
        let acTags = ["[grim", "[vulcan", "[nocheatplus", "[ncp]", "[spartan", "[matrix", "[themis", "anticheat"]

        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let l = line.lowercased()
            guard let range = line.range(of: "]: ") else { continue }
            let msg = line[range.upperBound...]

            let first = msg.split(separator: " ", maxSplits: 1).first ?? ""
            let hitFlag = flagMarkers.contains { l.contains($0) }
            let hitAC = acTags.contains { l.contains($0) }
                && (l.contains("flag") || l.contains("fail") || l.contains("violation") || l.contains("cheat"))

            if hitFlag, isValidName(first) {
                var s = byName[String(first)] ?? Suspicion(name: String(first), flags: 0, rejoins: 0, samples: [])
                s.flags += 1
                if s.samples.count < 4 { s.samples.append(line.trimmingCharacters(in: .whitespaces)) }
                byName[String(first)] = s
            } else if hitAC {
                if let name = msg.split(separator: " ").first(where: { isValidName($0) && $0.count >= 3 }) {
                    var s = byName[String(name)] ?? Suspicion(name: String(name), flags: 0, rejoins: 0, samples: [])
                    s.flags += 1
                    if s.samples.count < 4 { s.samples.append(line.trimmingCharacters(in: .whitespaces)) }
                    byName[String(name)] = s
                }
            }

            if msg.hasSuffix(" joined the game") {
                let name = msg.dropLast(" joined the game".count)
                if isValidName(name) {
                    if let prev = lastJoin[String(name)], i - prev < 6 {
                        var s = byName[String(name)] ?? Suspicion(name: String(name), flags: 0, rejoins: 0, samples: [])
                        s.rejoins += 1
                        byName[String(name)] = s
                    }
                    lastJoin[String(name)] = i
                }
            }
        }

        return byName.values
            .filter { $0.flags > 0 || $0.rejoins >= 2 }
            .sorted { ($0.flags + $0.rejoins) > ($1.flags + $1.rejoins) }
    }
}
