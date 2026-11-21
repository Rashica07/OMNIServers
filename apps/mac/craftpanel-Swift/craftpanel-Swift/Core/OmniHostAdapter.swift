import Foundation

struct OmniHostDetection: Codable, Sendable {
    var launchTarget: String
}

/// OMNIHost servers run on PumpkinMC (see `PumpkinEngine`): one native binary, no Java.
nonisolated enum OmniHostAdapter {
    /// Folder is an OMNIHost server when it has Pumpkin's `pumpkin.toml` (or the older `omnihost.toml`).
    static func inspect(at path: URL, engine: URL? = PumpkinEngine.installedBinary()) -> OmniHostDetection? {
        let fm = FileManager.default
        for name in [PumpkinConfig.fileName, "omnihost.toml"] where fm.fileExists(atPath: path.appending(path: name).path) {
            return OmniHostDetection(launchTarget: engine?.path ?? "pumpkin")
        }
        return nil
    }

    /// The program to run: the absolute path stored with the server, else a file of that name in
    /// the server folder, else the installed engine. nil when none exists.
    static func resolveBinary(launchTarget: String, serverDir: URL,
                              engine: URL? = PumpkinEngine.installedBinary()) -> URL? {
        let fm = FileManager.default
        if launchTarget.hasPrefix("/"), fm.isExecutableFile(atPath: launchTarget) {
            return URL(fileURLWithPath: launchTarget)
        }
        let local = serverDir.appending(path: launchTarget)
        if !launchTarget.isEmpty, !launchTarget.hasPrefix("/"), fm.isExecutableFile(atPath: local.path) { return local }
        return engine
    }

    /// Shown when a server's engine file is gone and none is installed.
    static let missingEngineReason = "The OMNIHost engine isn't installed on this Mac. Create an OMNIHost server (or reinstall) to download it again."

    /// Pumpkin keeps its config, world, plugins and logs in the working folder, so run it there.
    /// It reads commands (`stop`) from stdin when it isn't attached to a terminal.
    static func startCommand(config: ServerConfig, engine: URL? = PumpkinEngine.installedBinary()) -> Process? {
        guard let exe = resolveBinary(launchTarget: config.launchTarget, serverDir: config.path, engine: engine) else { return nil }
        let p = Process()
        p.executableURL = exe
        p.currentDirectoryURL = config.path
        p.arguments = []
        return p
    }

    /// From Pumpkin's own log lines (checked against the real binary, 0.2.2+26.3-26.60).
    static func parseStatus(_ text: String) -> ServerStatus {
        let o = text.lowercased()
        if o.contains("server is now running") { return .running }
        if o.contains("received interrupt signal") || o.contains("stopped accepting incoming connections")
            || o.contains("stop requested") { return .stopping }
        if o.contains("panicked at") || o.contains("thread 'main' panicked") { return .crashed }
        return .unknown
    }

    /// Prepares an existing server folder before a start: the OMNIHost icon and favicon setting
    /// (servers made before they existed), without replacing an icon the user chose.
    static func prepareFolder(_ dir: URL) {
        PumpkinConfig.ensureFavicon(serverDir: dir)
        BrandingManager.installOmniHostIcon(serverDir: dir)
    }
}

/// Turns the engine's console output into short lines under the OMNIHost name:
/// `[12:00:00] Ready on port 25565`. Start-up chatter, banners and engine internals are dropped;
/// player, chat, warning and error lines are kept.
nonisolated enum OmniHostLog {
    private static let ansi = "\u{1B}\\[[0-9;]*m"
    private static let noise = [
        "donat", "discord", "report issues", "heavy development", "embedded test instance",
        "embedded context provider", "enabled dimensions", "loading minecraft:", "nethernet",
        "stopped accepting incoming", "ending player tasks", "plugins unloaded", "starting save",
        "starting worlds", "saving level", "saving chunks", "joining 1 threads", "schedule: waiting",
        "flushing", "completed worlds", "telemetry", "not a tty",
    ]

    /// Every spelling of the engine's name becomes OMNIHost.
    static func rename(_ s: String) -> String {
        s.replacingOccurrences(of: "pumpkin(mc)?", with: "OMNIHost", options: [.regularExpression, .caseInsensitive])
    }

    /// nil means "don't show this line".
    static func simplify(_ raw: String) -> String? {
        let clean = raw.replacingOccurrences(of: ansi, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { return nil }
        let pattern = #"^(\d{2}:\d{2}:\d{2})\s+(TRACE|DEBUG|INFO|WARN|ERROR)\s+(.*)$"#
        guard let m = clean.range(of: pattern, options: .regularExpression) else { return rename(clean) }
        let parts = clean[m].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return rename(clean) }
        let time = String(parts[0])
        let rest = parts[1].drop { $0 == " " }
        let level = rest.prefix { $0 != " " }
        let msg = rest.dropFirst(level.count).drop { $0 == " " }
        if level == "TRACE" || level == "DEBUG" { return nil }
        let lower = msg.lowercased()
        if noise.contains(where: { lower.contains($0) }) { return nil }

        let text: String
        if lower.hasPrefix("starting pumpkin") {
            text = "Starting OMNIHost (Minecraft \(PumpkinEngine.minecraftVersion))"
        } else if lower.contains("all worlds loaded") {
            text = "World loaded"
        } else if lower.contains("server is now running") {
            if let r = msg.range(of: #"Java Edition: [^\s|]*:(\d+)"#, options: .regularExpression),
               let port = msg[r].split(separator: ":").last {
                text = "Ready. Join on port \(port)"
            } else { text = "Ready" }
        } else if lower.contains("creating a new world") {
            text = "Creating a new world"
        } else if lower.contains("received interrupt signal") {
            text = "Stopping…"
        } else if lower.contains("the server has stopped") {
            text = "Stopped"
        } else if lower.contains("completed save") {
            text = "World saved"
        } else {
            text = rename(String(msg))
        }
        switch level {
        case "WARN": return "[\(time)] Warning: \(text)"
        case "ERROR": return "[\(time)] Error: \(text)"
        default: return "[\(time)] \(text)"
        }
    }
}
