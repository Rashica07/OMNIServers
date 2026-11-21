import Foundation

/// One line of the launch checklist shown under the server name while it starts.
nonisolated struct LaunchStep: Equatable, Sendable {
    let label: String
    let done: Bool
    let active: Bool
}

/// Pure helpers for the header: the address chip, the invite text and the launch checklist.
nonisolated enum LaunchInfo {
    static func address(lanIP: String?, port: UInt16) -> String {
        if let ip = lanIP, !ip.isEmpty { return "\(ip):\(port)" }
        return "localhost:\(port)"
    }

    /// The address friends should use: your own saved permanent address (playit.gg etc.) wins, then the free
    /// tunnel, then the home-network address.
    static func bestAddress(manual: String?, tunnel: String?, lan: String) -> String {
        for c in [manual, tunnel] {
            if let t = c?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        }
        return lan
    }

    static func inviteText(name: String, address: String, version: String?) -> String {
        var t = "Join my Minecraft server \"\(name)\"!\nAddress: \(address)\n"
        if let v = version, !v.isEmpty { t += "Game: Minecraft \(v)\n" }
        return t + "In Minecraft: Multiplayer → Add Server → paste the address."
    }

    /// Three honest steps taken from the real server state: the checklist only moves when the server does.
    static func steps(for status: ServerStatus) -> [LaunchStep] {
        switch status {
        case .starting:
            return [LaunchStep(label: "Java ready", done: true, active: false),
                    LaunchStep(label: "Loading the world", done: false, active: true),
                    LaunchStep(label: "Ready for players", done: false, active: false)]
        case .running:
            return [LaunchStep(label: "Java ready", done: true, active: false),
                    LaunchStep(label: "World loaded", done: true, active: false),
                    LaunchStep(label: "Ready for players", done: true, active: false)]
        default:
            return []
        }
    }
}
