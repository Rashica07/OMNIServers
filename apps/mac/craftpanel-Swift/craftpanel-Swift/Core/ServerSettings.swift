import Foundation

/// Structured view of `server.properties` for the settings panel. Direct
/// port of `settings.rs`. Two curated tiers plus the raw list: common
/// (what most people touch), advanced (the knobs experienced admins
/// reach for, each with a help note), all (every key, for hand-editing).
nonisolated enum SettingKind: String, Sendable {
    case bool, int, enumKind = "enum", text
}

nonisolated struct SettingField: Sendable, Identifiable {
    var id: String { key }
    var key: String
    var label: String
    var value: String
    var kind: SettingKind
    var options: [String]
    var help: String?
    var note: String?
}

nonisolated struct ServerSettingsResult: Sendable {
    var present: Bool
    var common: [SettingField] = []
    var advanced: [SettingField] = []
    /// Every key in file order, for the raw editor.
    var all: [(String, String)] = []
}

nonisolated enum ServerSettings {
    private struct Spec {
        let key: String
        let label: String
        let kind: SettingKind
        let options: [String]
        let defaultValue: String
        let help: String?
    }

    /// No-options overload — the common case (bool/int/text fields).
    private static func s(
        _ key: String, _ label: String, _ kind: SettingKind,
        _ defaultValue: String, _ help: String? = nil
    ) -> Spec {
        Spec(key: key, label: label, kind: kind, options: [], defaultValue: defaultValue, help: help)
    }

    /// Enum overload — takes the option list. Two overloads rather than
    /// one defaulted parameter because `options` sits *before*
    /// `defaultValue` when present but is skipped entirely when it
    /// isn't, which plain positional defaults can't express in Swift;
    /// resolved by argument type instead, matching every call site
    /// below exactly.
    private static func s(
        _ key: String, _ label: String, _ kind: SettingKind,
        _ options: [String], _ defaultValue: String, _ help: String? = nil
    ) -> Spec {
        Spec(key: key, label: label, kind: kind, options: options, defaultValue: defaultValue, help: help)
    }

    private static let difficulty = ["peaceful", "easy", "normal", "hard"]
    private static let gamemode = ["survival", "creative", "adventure", "spectator"]
    private static let levelType = [
        "minecraft:normal", "minecraft:flat", "minecraft:large_biomes",
        "minecraft:amplified", "minecraft:single_biome_surface",
    ]
    private static let compression = ["deflate", "none"]

    private static let common: [Spec] = [
        s("motd", "MOTD", .text, "A Minecraft Server"),
        s("difficulty", "Difficulty", .enumKind, difficulty, "easy"),
        s("gamemode", "Default game mode", .enumKind, gamemode, "survival"),
        s("max-players", "Max players", .int, "20"),
        s("pvp", "PvP", .bool, "true"),
        s("white-list", "Whitelist", .bool, "false",
          "When on, only players in whitelist.json can join."),
        s("online-mode", "Online mode (Mojang auth)", .bool, "true",
          "Off = offline/cracked. Anyone can join under any name unless an auth mod enforces logins."),
        s("allow-flight", "Allow flight", .bool, "false",
          "Needed for elytra and some flight mods; without it the server kicks 'flying' players."),
        s("hardcore", "Hardcore", .bool, "false"),
        s("enable-command-block", "Command blocks", .bool, "false"),
        s("spawn-protection", "Spawn protection radius", .int, "16",
          "Blocks around spawn only ops can build in. 0 disables it."),
    ]

    private static let advanced: [Spec] = [
        s("view-distance", "View distance (chunks)", .int, "10",
          "How far chunks are sent to clients. The single biggest RAM/bandwidth lever — 6–8 is fine for most."),
        s("simulation-distance", "Simulation distance (chunks)", .int, "10",
          "How far entities/redstone/crops actually tick. Lower = big CPU win. Often set below view-distance."),
        s("network-compression-threshold", "Network compression threshold", .int, "256",
          "Packets larger than this (bytes) get compressed. -1 disables compression (LAN only); 512 eases CPU on busy servers."),
        s("max-tick-time", "Watchdog max tick time (ms)", .int, "60000",
          "The watchdog kills the server if a tick hangs this long. Set to -1 to disable the watchdog while debugging."),
        s("entity-broadcast-range-percentage", "Entity broadcast range %", .int, "100",
          "How far entities are visible to clients, as a % of view-distance. 50–75 cuts entity packet spam."),
        s("player-idle-timeout", "Idle kick (minutes)", .int, "0",
          "Auto-kick AFK players after N minutes. 0 = never."),
        s("pause-when-empty-seconds", "Pause when empty (seconds)", .int, "60",
          "Newer servers idle the tick loop when no one's online. -1 keeps it always running (needed for AFK farms)."),
        s("sync-chunk-writes", "Synchronous chunk writes", .bool, "true",
          "Safer on crash, but a latency spike on some disks. Many admins set this false on SSDs."),
        s("use-native-transport", "Native transport (epoll/kqueue)", .bool, "true",
          "Linux/macOS netty optimisation. Leave on unless it misbehaves."),
        s("max-world-size", "Max world border (blocks)", .int, "29999984"),
        s("level-type", "Level type", .enumKind, levelType, "minecraft:normal",
          "World generator. Only takes effect when the world is first created."),
        s("level-seed", "Level seed", .text, "",
          "Only used when generating a new world."),
        s("spawn-monsters", "Spawn monsters", .bool, "true"),
        s("allow-nether", "Allow the Nether", .bool, "true"),
        s("enable-query", "GameSpy query protocol", .bool, "false",
          "Lets server-list sites read player counts. Pairs with query.port."),
        s("query.port", "Query port", .int, "25565"),
        s("prevent-proxy-connections", "Block proxy/VPN logins", .bool, "false",
          "Rejects players whose ISP country doesn't match their Mojang session. Can false-positive."),
        s("rate-limit", "Packet rate limit", .int, "0",
          "Kick clients sending more than N packets/sec. 0 = off. 300–500 is a mild anti-crash setting."),
        s("enforce-secure-profile", "Require signed chat", .bool, "true",
          "Off allows unsigned chat / older clients; required off for most offline-mode setups."),
        s("op-permission-level", "Op permission level", .int, "4",
          "1 bypass spawn-protection · 2 /gamemode etc · 3 /ban · 4 /stop /op."),
        s("function-permission-level", "Function permission level", .int, "2"),
        s("region-file-compression", "Region file compression", .enumKind, compression, "deflate"),
    ]

    // --- Bedrock ---
    // Keys and defaults mirrored from settings.rs's own confirmation
    // against a real bedrock-server zip -- not guessed. A few fields
    // that plausibly have more valid values than observed
    // (compression-algorithm, chat-restriction) stay free text rather
    // than a guessed-at enum, so a legitimate value is never hidden.

    private static let bedrockGamemode = ["survival", "creative", "adventure"] // no "spectator"
    private static let bedrockPermission = ["visitor", "member", "operator"]

    private static let bedrockCommon: [Spec] = [
        s("server-name", "Server name", .text, "Dedicated Server"),
        s("gamemode", "Default game mode", .enumKind, bedrockGamemode, "survival"),
        s("difficulty", "Difficulty", .enumKind, difficulty, "easy"),
        s("max-players", "Max players", .int, "10"),
        s("allow-cheats", "Allow cheats", .bool, "false",
          "Lets players use commands and cheats in-world."),
        s("online-mode", "Xbox Live authentication", .bool, "true",
          "Off lets anyone connect without an Xbox Live account. Internet-facing servers should leave this on."),
        s("allow-list", "Allowlist only", .bool, "true",
          "When on, only players in allowlist.json can join."),
        s("level-seed", "Level seed", .text, "",
          "Only used when generating a new world."),
    ]

    private static let bedrockAdvanced: [Spec] = [
        s("view-distance", "View distance (chunks)", .int, "32"),
        s("tick-distance", "Simulation distance (chunks)", .int, "4",
          "How far entities/redstone/crops actually tick."),
        s("player-idle-timeout", "Idle kick (minutes)", .int, "30",
          "0 = never kick idle players."),
        s("max-threads", "Max worker threads", .int, "8"),
        s("default-player-permission-level", "Default permission level", .enumKind, bedrockPermission, "member"),
        s("texturepack-required", "Require the resource pack", .bool, "false"),
        s("content-log-file-enabled", "Write a content log file", .bool, "false"),
        s("compression-threshold", "Compression threshold", .int, "1"),
        s("compression-algorithm", "Compression algorithm", .text, "zlib"),
        s("chat-restriction", "Chat restriction", .text, "None", "None, Dropped, or Disabled."),
        s("disable-player-interaction", "Disable player-to-player interaction", .bool, "false"),
        s("server-portv6", "IPv6 port", .int, "19133"),
    ]

    private static func field(_ props: Properties, _ spec: Spec) -> SettingField {
        let value = props.get(spec.key) ?? spec.defaultValue
        let note = (spec.key == "online-mode" && value == "false")
            ? "This server is offline / cracked."
            : nil
        return SettingField(
            key: spec.key, label: spec.label, value: value, kind: spec.kind,
            options: spec.options, help: spec.help, note: note
        )
    }

    static func read(serverDir: String, serverType: ServerType) -> ServerSettingsResult {
        let props = Properties.load(dir: URL(fileURLWithPath: serverDir))
        guard props.existed else {
            return ServerSettingsResult(present: false)
        }
        let (commonSpecs, advancedSpecs) = serverType.isBedrock ? (bedrockCommon, bedrockAdvanced) : (common, advanced)
        return ServerSettingsResult(
            present: true,
            common: commonSpecs.map { field(props, $0) },
            advanced: advancedSpecs.map { field(props, $0) },
            all: props.entries()
        )
    }

    /// Apply key -> value changes, byte-preserving every untouched line.
    /// Returns the keys that actually changed.
    @discardableResult
    static func apply(serverDir: String, changes: [(String, String)]) throws -> [String] {
        let dir = URL(fileURLWithPath: serverDir)
        var props = Properties.load(dir: dir)
        guard props.existed else {
            throw RconServiceError.message("No server.properties yet — start the server once first.")
        }
        var changed: [String] = []
        for (k, v) in changes {
            guard isValidKey(k) else {
                throw RconServiceError.message("Rejected suspicious key: \(k)")
            }
            if props.set(k, v) {
                changed.append(k)
            }
        }
        try props.save()
        return changed
    }

    private static func isValidKey(_ k: String) -> Bool {
        !k.isEmpty && k.utf8.count < 128
            && k.utf8.allSatisfy { $0.isAsciiAlphanumeric || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") }
    }
}

private nonisolated extension UInt8 {
    var isAsciiAlphanumeric: Bool {
        (0x30...0x39).contains(self) || (0x41...0x5a).contains(self) || (0x61...0x7a).contains(self)
    }
}
