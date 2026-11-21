import Foundation

/// A concrete server flavour OMNIServers knows how to launch and read.
/// Mirrors `adapter::ServerType` in the Rust core exactly — same cases,
/// same kebab-case wire format, so a shared detection payload (if the
/// Swift and Rust builds ever need to agree on one, e.g. over a local
/// API) doesn't need translation at the boundary.
/// `nonisolated` because it's a plain, stateless value type read from many
/// nonisolated contexts (detection code, session/settings readers) — the
/// file's default MainActor isolation would otherwise make every one of
/// those a warning.
nonisolated enum ServerType: String, Codable, CaseIterable, Sendable {
    case fabric
    case forge
    /// NeoForge (the Forge fork). Stored separately from Forge — the Rust
    /// app lumped them together, which made Modrinth search the wrong
    /// loader and Crossplay offer a NeoForge Geyser build to real Forge.
    case neoforge
    case paper
    case spigot
    /// Generic `server.jar` with no mod/plugin loader detected.
    case vanilla
    /// Native Bedrock Dedicated Server — not a JVM process at all. See
    /// `BedrockAdapter`'s doc comment for what does and doesn't carry
    /// over from the Java adapters (no RCON, no `eula.txt`, different
    /// world format).
    case bedrock
    /// GTA V multiplayer. No macOS server exists; Windows/Linux only.
    case fivem
    case terraria
    /// Native Rust Minecraft server implementation under the OMNI ecosystem.
    case omnihost

    var label: String {
        switch self {
        case .fabric: "Fabric"
        case .forge: "Forge"
        case .neoforge: "NeoForge"
        case .paper: "Paper"
        case .spigot: "Spigot"
        case .vanilla: "Vanilla"
        case .bedrock: "Bedrock"
        case .fivem: "FiveM"
        case .terraria: "Terraria"
        case .omnihost: "OMNIHost"
        }
    }

    /// True if this flavour loads mods from a `mods/` folder.
    var usesModsFolder: Bool {
        self == .fabric || self == .forge || self == .neoforge
    }

    /// True for the native Bedrock Dedicated Server — a plain OS process,
    /// not a JVM. Callers use this to skip everything that assumes
    /// `java`: heap flags, `-jar`, RCON, `eula.txt`.
    var isBedrock: Bool { self == .bedrock }

    /// Native Rust engine under the OMNI ecosystem — no JVM required.
    var isOmniHost: Bool { self == .omnihost }

    /// A non-Minecraft game server: its own program and config file, no Java, no RCON.
    var isGame: Bool { self == .fivem || self == .terraria }
    /// Runs on Java (every Minecraft Java flavour except native OMNIHost).
    var usesJava: Bool { !(isBedrock || isGame || isOmniHost) }

    /// Forge-family servers launch through an `@…args.txt` file.
    var isForgeFamily: Bool { self == .forge || self == .neoforge }
}
