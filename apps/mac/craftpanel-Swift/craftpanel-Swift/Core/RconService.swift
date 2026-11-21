import Foundation

nonisolated struct RconSettingsInfo: Sendable {
    var enabled: Bool
    var port: UInt16
    var hasPassword: Bool
    var broadcastToOps: Bool
    var propertiesPresent: Bool
}

nonisolated struct RconSetupResult: Sendable {
    var changed: [String]
    var port: UInt16
    var restartRequired: Bool
}

nonisolated enum RconServiceError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let s): s }
    }
}

/// Ties the RCON transport (`RconClient`/`RconPool`) to a `ServerRecord`
/// — endpoint resolution, player actions, and RCON setup. Direct port of
/// `commands.rs`'s `rcon_endpoint`/`rcon_run`/`rcon_player_action`/
/// `rcon_setup`/`rcon_settings`.
actor RconService {
    static let shared = RconService()

    private let pool = RconPool()

    /// Servers that are shutting down: a Minecraft server waits for every RCON client thread to finish before it exits, and a
    /// client that stays connected (our pooled one, kept alive for the Players tab) stalls the shutdown until it's force-killed.
    /// So when a stop starts, we hang up and don't reconnect. A restart clears it, and it expires on its own.
    private var shuttingDown: [UUID: Date] = [:]
    static let shutdownWindow: TimeInterval = 120

    func beginShutdown(_ id: UUID) async {
        shuttingDown[id] = Date()
        await pool.closeConnection(key: id)
    }

    func endShutdown(_ id: UUID) { shuttingDown[id] = nil }

    func isShuttingDown(_ id: UUID) -> Bool {
        guard let t = shuttingDown[id] else { return false }
        return Date().timeIntervalSince(t) < Self.shutdownWindow
    }

    /// Reads the RCON endpoint out of `server.properties`, with the same
    /// specific, actionable errors as the Rust source — never a bare
    /// "RCON unavailable".
    func endpoint(for record: ServerRecord) throws -> (port: UInt16, password: String) {
        let props = Properties.load(dir: URL(fileURLWithPath: record.path))
        guard props.existed else {
            throw RconServiceError.message("This server has no server.properties yet — start it once first.")
        }
        guard props.getOr("enable-rcon", "false") == "true" else {
            throw RconServiceError.message("RCON isn't enabled for this server. Run RCON setup first.")
        }
        guard let port = UInt16(props.getOr("rcon.port", "25575")) else {
            throw RconServiceError.message("rcon.port in server.properties isn't a number")
        }
        let password = props.get("rcon.password") ?? ""
        guard !password.isEmpty else {
            throw RconServiceError.message("rcon.password is blank — run RCON setup to generate one.")
        }
        return (port, password)
    }

    /// Run one RCON command through the pooled (kept-alive) connection.
    func run(record: ServerRecord, command: String) async throws -> String {
        if isShuttingDown(record.id) { throw RconServiceError.message("The server is shutting down.") }
        let (port, password) = try endpoint(for: record)
        return try await pool.run(key: record.id, host: "127.0.0.1", port: port, password: password) { client in
            try await client.command(command)
        }
    }

    func players(record: ServerRecord) async throws -> (online: Int, max: Int, players: [String]) {
        let out = try await run(record: record, command: "list")
        return RconClient.parsePlayerList(out)
    }

    /// Typed, validated player operations — all keyed on username
    /// (offline-safe).
    @discardableResult
    func playerAction(record: ServerRecord, action: String, player rawPlayer: String, arg: String? = nil) async throws -> String {
        let player = rawPlayer.trimmingCharacters(in: .whitespaces)
        guard !player.isEmpty, player.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw RconServiceError.message("Invalid player name.")
        }
        let cmd: String
        switch action {
        case "kick":
            let reason = arg?.trimmingCharacters(in: .whitespaces) ?? ""
            if !reason.isEmpty {
                guard reason.allSatisfy(Self.isSafeReasonChar) else {
                    throw RconServiceError.message("Kick reason has unsupported characters.")
                }
                cmd = "kick \(player) \(reason)"
            } else {
                cmd = "kick \(player)"
            }
        case "ban": cmd = "ban \(player)"
        case "pardon": cmd = "pardon \(player)"
        case "op": cmd = "op \(player)"
        case "deop": cmd = "deop \(player)"
        case "whitelist-add": cmd = "whitelist add \(player)"
        case "whitelist-remove": cmd = "whitelist remove \(player)"
        case "gamemode":
            let mode = arg ?? ""
            guard ["survival", "creative", "adventure", "spectator"].contains(mode) else {
                throw RconServiceError.message("Unknown gamemode.")
            }
            cmd = "gamemode \(mode) \(player)"
        default:
            throw RconServiceError.message("Unknown action: \(action)")
        }
        return try await run(record: record, command: cmd)
    }

    private static func isSafeReasonChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || " .,!?_-'".contains(c))
    }

    // MARK: - Setup

    func settings(for record: ServerRecord) -> RconSettingsInfo {
        let props = Properties.load(dir: URL(fileURLWithPath: record.path))
        return RconSettingsInfo(
            enabled: props.getOr("enable-rcon", "false") == "true",
            port: UInt16(props.getOr("rcon.port", "25575")) ?? 25575,
            hasPassword: !(props.get("rcon.password") ?? "").isEmpty,
            broadcastToOps: props.getOr("broadcast-rcon-to-ops", "true") == "true",
            propertiesPresent: props.existed
        )
    }

    /// Enable RCON in `server.properties`. Only ever writes the four RCON
    /// keys — never `online-mode` or anything else, same hard constraint
    /// as the Rust source.
    func setup(for record: ServerRecord, isRunning: Bool) throws -> RconSetupResult {
        let dir = URL(fileURLWithPath: record.path)
        var props = Properties.load(dir: dir)
        guard props.existed else {
            throw RconServiceError.message(
                "No server.properties yet. Start the server once so it generates its config, then enable RCON."
            )
        }

        var changed: [String] = []
        if props.set("enable-rcon", "true") { changed.append("enable-rcon=true") }

        let port = props.getOr("rcon.port", "")
        if port.isEmpty || UInt16(port) == nil {
            props.set("rcon.port", "25575")
            changed.append("rcon.port=25575")
        }
        if (props.get("rcon.password") ?? "").isEmpty {
            let pw = Self.generatePassword()
            props.set("rcon.password", pw)
            changed.append("rcon.password=(generated)")
        }
        if props.set("broadcast-rcon-to-ops", "true") { changed.append("broadcast-rcon-to-ops=true") }

        try props.save()

        let finalPort = UInt16(props.getOr("rcon.port", "25575")) ?? 25575
        return RconSetupResult(changed: changed, port: finalPort, restartRequired: isRunning)
    }

    /// Local RCON password; 24 hex chars from two v4 UUIDs is plenty.
    /// Matches `commands::gen_password` exactly.
    private static func generatePassword() -> String {
        let a = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let b = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String((a + b).prefix(24))
    }
}
