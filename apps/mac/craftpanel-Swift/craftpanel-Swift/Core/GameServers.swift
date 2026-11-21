import Foundation

/// What was found in a folder that holds a non-Minecraft game server.
nonisolated struct GameDetection: Sendable, Equatable {
    var type: ServerType
    var launchTarget: String
    var evidence: String
}

nonisolated struct GameFixResult: Sendable, Equatable {
    var done: [String]
    var todo: [String]
}

/// FiveM and Terraria: find the server files, repair the setup, build the launch command, read the console.
/// Same behaviour as the Windows app's `GameServers`.
nonisolated enum GameServers {
    static let bannerLine = "MADE WITH OMNISERVERS"

    static func banner(game: String) -> String {
        let art = """
 ██████╗ ███╗   ███╗███╗   ██╗██╗
██╔═══██╗████╗ ████║████╗  ██║██║
██║   ██║██╔████╔██║██╔██╗ ██║██║
██║   ██║██║╚██╔╝██║██║╚██╗██║██║
╚██████╔╝██║ ╚═╝ ██║██║ ╚████║██║
 ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝
███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ ███████╗
██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗██╔════╝
███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝███████╗
╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗╚════██║
███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║███████║
╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝╚══════╝
"""
        return art + "\n      " + bannerLine + "  ·  " + game
    }

    static func defaultPort(_ t: ServerType) -> Int {
        switch t { case .fivem: 30120; case .terraria: 7777; case .bedrock: 19132; default: 25565 }
    }

    static func stopCommand(_ t: ServerType) -> String {
        switch t { case .fivem: "quit"; case .terraria: "exit"; default: "stop" }
    }

    /// FiveM's server software only exists for Windows and Linux.
    static func isPlatformSupported(_ t: ServerType) -> Bool { t != .fivem }

    private static func exists(_ dir: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appending(path: name).path)
    }

    static func inspect(at dir: URL) -> GameDetection? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        if exists(dir, "FXServer.exe") { return GameDetection(type: .fivem, launchTarget: "FXServer.exe", evidence: "FXServer.exe") }
        if exists(dir, "run.sh"), exists(dir, "alpine") || exists(dir, "server.cfg") || exists(dir, "resources") {
            return GameDetection(type: .fivem, launchTarget: "run.sh", evidence: "run.sh")
        }
        let appLauncher = "Terraria Server.app/Contents/MacOS/TerrariaServer"
        if exists(dir, appLauncher) { return GameDetection(type: .terraria, launchTarget: appLauncher, evidence: "Terraria Server.app") }
        for f in ["TerrariaServer.bin.osx", "TerrariaServer.bin.x86_64", "TerrariaServer.exe", "TerrariaServer"] where exists(dir, f) {
            return GameDetection(type: .terraria, launchTarget: f, evidence: f)
        }
        return nil
    }

    static func startCommand(config: ServerConfig) -> Process {
        let p = Process()
        p.executableURL = config.path.appending(path: config.launchTarget)
        p.currentDirectoryURL = config.path
        p.arguments = config.serverType == .fivem ? ["+exec", "server.cfg"] : ["-config", config.path.appending(path: "serverconfig.txt").path]
        return p
    }

    static func parseStatus(_ t: ServerType, output: String) -> ServerStatus {
        let o = output.lowercased()
        if t == .fivem {
            if o.contains("server thread is now running") || o.contains("server started") || o.contains("started resource monitor") { return .running }
            if o.contains("shutting down") { return .stopping }
        } else if t == .terraria {
            if o.contains("server started") { return .running }
            if o.contains("saving world") || o.contains("shutting down") { return .stopping }
        }
        return .unknown
    }

    /// Repairs a game server folder so it can start. Returns what it changed and what you must still do yourself.
    static func fix(type: ServerType, dir: URL, name: String) -> GameFixResult {
        var done: [String] = [], todo: [String] = []
        if type == .fivem { fixFiveM(dir, name, &done, &todo) } else if type == .terraria { fixTerraria(dir, name, &done, &todo) }
        return GameFixResult(done: done, todo: todo)
    }

    private static func pass() -> String {
        (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func resourceExists(_ dir: URL, _ name: String) -> Bool {
        let root = dir.appending(path: "resources")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        for case let u as URL in e where u.lastPathComponent == name { return true }
        return false
    }

    private static func fixFiveM(_ dir: URL, _ name: String, _ done: inout [String], _ todo: inout [String]) {
        let cfg = dir.appending(path: "server.cfg")
        let fm = FileManager.default
        if !fm.fileExists(atPath: cfg.path) {
            var t = "# Made by OMNIServers. Edit freely.\n"
            t += "endpoint_add_tcp \"0.0.0.0:30120\"\nendpoint_add_udp \"0.0.0.0:30120\"\n\n"
            t += "sv_hostname \"\(name.replacingOccurrences(of: "\"", with: ""))\"\nsv_maxclients 32\nset sv_enforceGameBuild 3095\n"
            t += "sv_licenseKeyToken \"PASTE-YOUR-KEY-HERE\"\nset rcon_password \"\(pass())\"\n\n"
            for r in ["mapmanager", "chat", "spawnmanager", "sessionmanager", "basic-gamemode", "hardcap", "rconlog"] where resourceExists(dir, r) {
                t += "ensure \(r)\n"
            }
            try? t.write(to: cfg, atomically: true, encoding: .utf8)
            done.append("Created server.cfg with the standard ports and resources.")
        } else if var text = try? String(contentsOf: cfg, encoding: .utf8) {
            var add = ""
            if !text.localizedCaseInsensitiveContains("endpoint_add_tcp") { add += "endpoint_add_tcp \"0.0.0.0:30120\"\n"; done.append("Added the missing TCP port (30120) to server.cfg.") }
            if !text.localizedCaseInsensitiveContains("endpoint_add_udp") { add += "endpoint_add_udp \"0.0.0.0:30120\"\n"; done.append("Added the missing UDP port (30120) to server.cfg.") }
            if !text.localizedCaseInsensitiveContains("rcon_password") { add += "set rcon_password \"\(pass())\"\n"; done.append("Set an RCON password so the console can be reached.") }
            if !add.isEmpty {
                text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + add
                try? text.write(to: cfg, atomically: true, encoding: .utf8)
            }
        }
        let final = (try? String(contentsOf: cfg, encoding: .utf8)) ?? ""
        let hasKey = final.range(of: #"sv_licenseKey(Token)?\s+"?(?!PASTE-YOUR-KEY-HERE)[A-Za-z0-9_-]{8,}"#, options: [.regularExpression, .caseInsensitive]) != nil
        if !hasKey { todo.append("FiveM needs your own free licence key. Get it at keymaster.fivem.net and paste it into server.cfg (sv_licenseKeyToken).") }
        if !fm.fileExists(atPath: dir.appending(path: "resources").path) {
            todo.append("No resources folder here. Download cfx-server-data and put its resources folder next to the server files.")
        }
    }

    private static func safeName(_ n: String) -> String {
        let s = String(n.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return s.isEmpty ? "World" : s
    }

    private static func fixTerraria(_ dir: URL, _ name: String, _ done: inout [String], _ todo: inout [String]) {
        let cfg = dir.appending(path: "serverconfig.txt")
        let worlds = dir.appending(path: "Worlds")
        let fm = FileManager.default
        try? fm.createDirectory(at: worlds, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: cfg.path) {
            let existing = (try? fm.contentsOfDirectory(at: worlds, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "wld" }
            var t = "# Made by OMNIServers. Edit freely.\n"
            if let e = existing { t += "world=\(e.path)\n" } else {
                t += "world=\(worlds.appending(path: safeName(name) + ".wld").path)\nautocreate=2\nworldname=\(safeName(name))\n"
            }
            t += "worldpath=\(worlds.path)\nmaxplayers=8\nport=7777\npassword=\nmotd=Made with OMNIServers\n"
            try? t.write(to: cfg, atomically: true, encoding: .utf8)
            done.append(existing == nil ? "Created serverconfig.txt. A new medium world is made on first start." : "Created serverconfig.txt and pointed it at your existing world.")
        } else if var text = try? String(contentsOf: cfg, encoding: .utf8),
                  text.range(of: #"^\s*port\s*="#, options: [.regularExpression, .caseInsensitive]) == nil,
                  !text.lowercased().contains("\nport=") {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\nport=7777\n"
            try? text.write(to: cfg, atomically: true, encoding: .utf8)
            done.append("Added the port (7777) to serverconfig.txt.")
        }
    }
}
