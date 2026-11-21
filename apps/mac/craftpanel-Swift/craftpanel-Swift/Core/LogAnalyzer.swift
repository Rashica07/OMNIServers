import Foundation

/// Reads a server log and says, in plain words, what looks wrong and what
/// to do about it. Pure text in, findings out, so it's easy to test.
struct LogFinding: Equatable, Identifiable {
    enum Severity { case error, warning }
    let id: String
    let severity: Severity
    let title: String
    let advice: String
}

enum LogAnalyzer {
    private struct Rule {
        let id: String
        let severity: LogFinding.Severity
        let patterns: [String]
        let title: String
        let advice: String
    }

    private static let rules: [Rule] = [
        Rule(id: "eula", severity: .error, patterns: ["you need to agree to the eula", "eula.txt"],
             title: "The Minecraft EULA isn't accepted",
             advice: "Start the server from OMNIServers once and accept the EULA, or set eula=true in eula.txt."),
        Rule(id: "port", severity: .error, patterns: ["address already in use", "failed to bind to port", "perhaps a server is already running"],
             title: "The port is already taken",
             advice: "Another server or app is using this port. Stop it, or change the server port in Network."),
        Rule(id: "java-version", severity: .error, patterns: ["unsupportedclassversionerror", "has been compiled by a more recent version of the java runtime"],
             title: "This server needs a newer Java",
             advice: "Pick a newer Java in the server's launch settings (Minecraft 1.20.5 and up needs Java 21)."),
        Rule(id: "oom", severity: .error, patterns: ["java.lang.outofmemoryerror", "could not reserve enough space"],
             title: "The server ran out of memory",
             advice: "Give it more memory in Settings, or remove heavy mods. Keep some memory free for your computer."),
        Rule(id: "dependency", severity: .error, patterns: ["missing or unsupported mandatory dependencies", "requires mod", "missing mandatory dependencies", "could not find required mod"],
             title: "A mod is missing something it needs",
             advice: "Open Mods and add the library mod it names (often Fabric API or a matching Forge version)."),
        Rule(id: "duplicate-mod", severity: .error, patterns: ["duplicate mod", "duplicate mods", "found duplicate"],
             title: "The same mod is installed twice",
             advice: "Open Mods and delete one copy of the mod it names."),
        Rule(id: "mixin", severity: .error, patterns: ["mixin apply failed", "mixintransformererror", "invalidmixinexception"],
             title: "Two mods clash",
             advice: "Turn off the most recently added mod in Mods, then start again. Update both if you can."),
        Rule(id: "world", severity: .error, patterns: ["failed to load level", "failed to read level.dat", "world is corrupted"],
             title: "The world won't load",
             advice: "Restore a backup from Backups. A world saved by a newer Minecraft version can't load on an older server."),
        Rule(id: "cant-keep-up", severity: .warning, patterns: ["can't keep up!"],
             title: "The server is lagging",
             advice: "Lower view distance, give it more memory, or switch to Paper."),
        Rule(id: "plugin-error", severity: .warning, patterns: ["could not load 'plugins/", "error occurred while enabling"],
             title: "A plugin failed to load",
             advice: "Open Mods & plugins and update or remove the plugin named in the log."),
        Rule(id: "offline", severity: .warning, patterns: ["failed to verify username", "authentication servers are down"],
             title: "Players can't sign in",
             advice: "Mojang's sign-in may be down, or the player's account isn't verified. Try again in a few minutes."),
    ]

    static func analyze(_ log: String) -> [LogFinding] {
        let lower = log.lowercased()
        return rules.compactMap { r in
            r.patterns.contains(where: lower.contains)
                ? LogFinding(id: r.id, severity: r.severity, title: r.title, advice: r.advice) : nil
        }
    }
}
