import Foundation

/// Visual settings for a handful of very common plugins — EssentialsX,
/// LuckPerms, Geyser — instead of hand-editing YAML. Not a general YAML
/// parser or writer: line-based, indentation-aware lookup/replace for a
/// fixed, hand-verified list of keys per plugin, same line-preserving
/// discipline `Properties` already uses for `server.properties` — every
/// other byte in the file (comments, key order, everything not in this
/// list) is left exactly as it was. Direct port of `pluginconfig.rs`.
///
/// Deliberately small: these three plugins ship *hundreds* of settings
/// between them. This covers the handful worth a toggle/slider instead
/// of a text field — anything else, the file's still just a file,
/// editable as text in the Files tab like always.
nonisolated enum FieldKind: String, Sendable {
    case bool, int, text, select
}

nonisolated struct FieldSpec: Sendable {
    /// "key" for a top-level key, or "parent.key" for one level of nesting
    let key: String
    let label: String
    let hint: String
    let kind: FieldKind
    let options: [String]
    let min: Int64?
    let max: Int64?

    init(_ key: String, _ label: String, _ hint: String, _ kind: FieldKind, options: [String] = [], min: Int64? = nil, max: Int64? = nil) {
        self.key = key; self.label = label; self.hint = hint; self.kind = kind
        self.options = options; self.min = min; self.max = max
    }
}

nonisolated struct KnownPlugin: Sendable {
    let id: String
    let name: String
    /// candidate relative paths — first one that exists on disk wins
    let paths: [String]
    let fields: [FieldSpec]
}

nonisolated struct FieldView: Sendable, Identifiable {
    var id: String { key }
    var key: String
    var label: String
    var hint: String
    var kind: FieldKind
    var options: [String]
    var min: Int64?
    var max: Int64?
    var value: String?
}

nonisolated struct PluginConfigView: Sendable, Identifiable {
    var id: String { plugin }
    var plugin: String
    var name: String
    var file: String
    var fields: [FieldView]
}

nonisolated enum PluginConfig {
    static let essentialsX = KnownPlugin(
        id: "essentialsx", name: "EssentialsX", paths: ["plugins/Essentials/config.yml"],
        fields: [
            FieldSpec("currency-symbol", "Currency symbol", "Shown before balances, e.g. in /balance.", .text),
            FieldSpec("starting-balance", "Starting balance", "What a new player's wallet starts with.", .int, min: 0),
            FieldSpec("max-money", "Maximum balance", "A wallet can't go above this.", .int, min: 0),
            FieldSpec("min-money", "Minimum balance", "How far into debt a wallet can go (usually 0 or negative).", .int),
            FieldSpec("spawn-on-join", "Spawn on join", "Send players to world spawn every time they join, not just the first time.", .bool),
            FieldSpec("respawn-at-home", "Respawn at home", "After dying, respawn at /sethome instead of world spawn.", .bool),
            FieldSpec("teleport-safety", "Safe teleports", "Nudge a teleport that would land inside a wall or over a void to the nearest safe spot.", .bool),
            FieldSpec("is-water-safe", "Water counts as safe", "Let /home, /spawn etc. land in water without being pushed elsewhere.", .bool),
        ]
    )

    static let luckPerms = KnownPlugin(
        id: "luckperms", name: "LuckPerms", paths: ["plugins/LuckPerms/config.yml"],
        fields: [
            FieldSpec("server", "Server name", "Used for server-specific permissions. \"global\" applies everywhere.", .text),
            FieldSpec("storage-method", "Storage method", "Where permission/group data actually lives.", .select,
                       options: ["h2", "sqlite", "json", "yaml", "hocon", "mysql", "mariadb", "postgresql", "mongodb"]),
            FieldSpec("enable-ops", "Vanilla /op", "Let vanilla server-operator status still work alongside LuckPerms.", .bool),
            FieldSpec("auto-op", "Auto-op for admin group", "Automatically grant vanilla op to anyone with admin permissions.", .bool),
            FieldSpec("debug-logins", "Debug logins", "Log extra detail about permission calculation on every join — noisy, diagnostic only.", .bool),
            FieldSpec("allow-invalid-usernames", "Allow invalid usernames", "Accept player names that don't match Minecraft's normal username rules (some proxies need this).", .bool),
        ]
    )

    static let geyser = KnownPlugin(
        id: "geyser", name: "Geyser",
        paths: ["plugins/Geyser-Spigot/config.yml", "config/Geyser-Fabric/config.yml", "config/geyser-neoforge/config.yml"],
        fields: [
            FieldSpec("bedrock.address", "Listen address", "Which network interface accepts Bedrock connections — 0.0.0.0 means all of them.", .text),
            FieldSpec("bedrock.port", "Bedrock port", "The UDP port Bedrock players connect to. Also shown on the Network tab.", .int, min: 1, max: 65535),
            FieldSpec("bedrock.clone-remote-port", "Match the Java port", "Some hosts change your Java port on every restart — this keeps Bedrock's port matching it automatically.", .bool),
        ]
    )

    static let known = [essentialsX, luckPerms, geyser]

    static func splitKey(_ key: String) -> (String?, String) {
        guard let dot = key.firstIndex(of: ".") else { return (nil, key) }
        return (String(key[key.startIndex..<dot]), String(key[key.index(after: dot)...]))
    }

    /// A `#` preceded by whitespace (or at the start) and not inside quotes.
    static func stripTrailingComment(_ s: String) -> String {
        var quote: Character?
        var prevWS = true
        for (i, c) in s.enumerated() {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "#", prevWS {
                let idx = s.index(s.startIndex, offsetBy: i)
                return String(s[s.startIndex..<idx])
            }
            prevWS = c.isWhitespace
        }
        return s
    }

    static func cleanScalar(_ raw: String) -> String {
        let t = stripTrailingComment(raw).trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let first = t.first, let last = t.last,
           (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    static func getTopLevel(_ text: String, _ key: String) -> String? {
        let prefix = "\(key):"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            if line.hasPrefix(prefix) {
                return cleanScalar(String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    static func getNested(_ text: String, _ parent: String, _ key: String) -> String? {
        let parentPrefix = "\(parent):"
        let childPrefix = "\(key):"
        var inBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if !indented {
                inBlock = line.hasPrefix(parentPrefix)
                continue
            }
            guard inBlock else { continue }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix(childPrefix) {
                return cleanScalar(String(trimmed.dropFirst(childPrefix.count)))
            }
        }
        return nil
    }

    static func getValue(_ text: String, _ key: String) -> String? {
        let (parent, k) = splitKey(key)
        if let parent { return getNested(text, parent, k) }
        return getTopLevel(text, k)
    }

    /// Replace one known key's value, quoting it if `quote`. Every other
    /// line — comments, blank lines, everything else — passes through
    /// byte-for-byte.
    static func setValue(_ text: String, _ key: String, _ newValue: String, quote: Bool) throws -> String {
        let (parent, child) = splitKey(key)
        let formatted = quote ? "'\(newValue.replacingOccurrences(of: "'", with: "''"))'" : newValue
        let childPrefix = "\(child):"
        let parentPrefix = parent.map { "\($0):" }

        var inBlock = parent == nil
        var found = false
        var out: [Substring] = []
        let hadTrailingNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLastIfTrailingNewline(hadTrailingNewline)

        for line in lines {
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if let pp = parentPrefix {
                if !indented {
                    inBlock = line.hasPrefix(pp)
                    out.append(line)
                    continue
                }
                if !inBlock {
                    out.append(line)
                    continue
                }
            } else if indented {
                out.append(line)
                continue
            }

            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line[line.startIndex..<line.index(line.startIndex, offsetBy: line.count - trimmed.count)]
            if !found, trimmed.hasPrefix(childPrefix) {
                out.append(Substring("\(indent)\(child): \(formatted)"))
                found = true
            } else {
                out.append(line)
            }
        }

        guard found else {
            throw RconServiceError.message("'\(key)' wasn't found in this file — it may have been removed or renamed past what OMNIServers expects. Edit it directly in the Files tab instead.")
        }
        var result = out.joined(separator: "\n")
        if hadTrailingNewline { result.append("\n") }
        return result
    }

    private static func findFile(serverDir: URL, plugin: KnownPlugin) -> (String, String)? {
        for rel in plugin.paths {
            let url = serverDir.appendingPathComponent(rel)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return (rel, text)
            }
        }
        return nil
    }

    /// Every known plugin whose config file actually exists in this
    /// server — usually zero, one, or (Geyser + EssentialsX, say) a couple.
    static func detect(serverDir: URL) -> [PluginConfigView] {
        known.compactMap { plugin in
            guard let (rel, text) = findFile(serverDir: serverDir, plugin: plugin) else { return nil }
            let fields = plugin.fields.map { f in
                FieldView(key: f.key, label: f.label, hint: f.hint, kind: f.kind, options: f.options, min: f.min, max: f.max, value: getValue(text, f.key))
            }
            return PluginConfigView(plugin: plugin.id, name: plugin.name, file: rel, fields: fields)
        }
    }

    /// Write one field back. `pluginID` + `key` must match one of
    /// `known`'s field specs — this never writes an arbitrary path the
    /// UI made up.
    static func setField(serverDir: URL, pluginID: String, key: String, value: String) throws {
        guard let plugin = known.first(where: { $0.id == pluginID }) else {
            throw RconServiceError.message("Unknown plugin '\(pluginID)'.")
        }
        guard let field = plugin.fields.first(where: { $0.key == key }) else {
            throw RconServiceError.message("'\(key)' isn't a setting OMNIServers manages for \(plugin.name).")
        }

        if field.kind == .int {
            guard let n = Int64(value) else {
                throw RconServiceError.message("That needs to be a whole number.")
            }
            if let min = field.min, n < min {
                throw RconServiceError.message("\(field.label) can't go below \(min).")
            }
            if let max = field.max, n > max {
                throw RconServiceError.message("\(field.label) can't go above \(max).")
            }
        }
        if field.kind == .select, !field.options.contains(value) {
            throw RconServiceError.message("'\(value)' isn't a valid \(field.label).")
        }

        guard let (rel, text) = findFile(serverDir: serverDir, plugin: plugin) else {
            throw RconServiceError.message("\(plugin.name)'s config file wasn't found — is it installed?")
        }
        let quote = field.kind == .text
        let updated = try setValue(text, key, value, quote: quote)
        try updated.write(to: serverDir.appendingPathComponent(rel), atomically: true, encoding: .utf8)
    }
}

nonisolated private extension Array where Element == Substring {
    /// `String.split(separator:omittingEmptySubsequences:false)` produces
    /// a trailing empty element for a `\n`-terminated string, which
    /// Rust's `.lines()` doesn't — dropped here so line-by-line rewrites
    /// match exactly, same fix already applied in `Properties`.
    func dropLastIfTrailingNewline(_ hadTrailingNewline: Bool) -> [Substring] {
        if hadTrailingNewline, last == "" { return Array(dropLast()) }
        return self
    }
}
