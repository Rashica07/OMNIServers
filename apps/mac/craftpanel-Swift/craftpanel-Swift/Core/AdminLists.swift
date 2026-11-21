import Foundation

/// Ops / whitelist / bans overview for a server. Direct port of
/// `admin.rs`. Reading is always available (parse the JSON files
/// Minecraft keeps) — changes go through RCON while the server is up,
/// which is offline-mode safe since everything here is keyed on name,
/// never a synthesised UUID.
nonisolated struct BannedEntry: Sendable, Identifiable {
    var id: String { name }
    var name: String
    var reason: String?
}

nonisolated struct AdminLists: Sendable {
    var ops: [String] = []
    var whitelist: [String] = []
    var banned: [BannedEntry] = []
    var bannedIPs: [String] = []
    /// `white-list=true` in server.properties
    var whitelistOn: Bool = false
    /// `enforce-whitelist=true`
    var enforceWhitelist: Bool = false

    private struct NameOnly: Decodable { var name: String? }
    private struct BanRow: Decodable { var name: String?; var reason: String? }
    private struct IPRow: Decodable { var ip: String? }

    private static func names(dir: URL, file: String) -> [String] {
        guard let data = try? Data(contentsOf: dir.appending(path: file)),
              let rows = try? JSONDecoder().decode([NameOnly].self, from: data) else {
            return []
        }
        return rows.compactMap(\.name)
    }

    static func read(serverDir: String) -> AdminLists {
        let dir = URL(fileURLWithPath: serverDir)
        let props = Properties.load(dir: dir)

        let banned: [BannedEntry] = {
            guard let data = try? Data(contentsOf: dir.appending(path: "banned-players.json")),
                  let rows = try? JSONDecoder().decode([BanRow].self, from: data) else {
                return []
            }
            return rows.compactMap { row in
                guard let name = row.name else { return nil }
                let reason = row.reason.flatMap { $0.isEmpty ? nil : $0 }
                return BannedEntry(name: name, reason: reason)
            }
        }()

        let bannedIPs: [String] = {
            guard let data = try? Data(contentsOf: dir.appending(path: "banned-ips.json")),
                  let rows = try? JSONDecoder().decode([IPRow].self, from: data) else {
                return []
            }
            return rows.compactMap(\.ip)
        }()

        return AdminLists(
            ops: names(dir: dir, file: "ops.json"),
            whitelist: names(dir: dir, file: "whitelist.json"),
            banned: banned,
            bannedIPs: bannedIPs,
            whitelistOn: props.getOr("white-list", "false") == "true",
            enforceWhitelist: props.getOr("enforce-whitelist", "false") == "true"
        )
    }
}
