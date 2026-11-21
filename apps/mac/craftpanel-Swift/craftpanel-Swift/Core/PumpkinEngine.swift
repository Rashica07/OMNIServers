import Foundation
import CryptoKit

/// The engine behind OMNIHost: PumpkinMC, a native Rust Minecraft server (GPLv3).
///
/// OMNIServers does not bundle it. It downloads one pinned release from Pumpkin's GitHub
/// releases, checks the SHA-256 in that release's `checksums.sha256`, and keeps it under
/// `Application Support/CraftPanel/engines/pumpkin/<tag>/pumpkin`. A server records the
/// absolute path of the binary it was made with, so a later engine update never changes an
/// existing server by surprise.
nonisolated enum PumpkinEngine {
    /// The release that was run and checked by hand (2026-11-19). Newer tags are opt-in.
    static let pinnedTag = "0.2.2+26.3-26.60"
    /// The Java Minecraft version this release speaks.
    static let minecraftVersion = "26.3"
    static let releasesBase = "https://github.com/Pumpkin-MC/Pumpkin/releases/download"
    private static let userAgent = "OMNIServers/1 pumpkin-install"

    // MARK: Which file

    /// The release asset for this computer, nil where Pumpkin ships no build.
    static func assetName(os: String = currentOS, arch: String = currentArch) -> String? {
        switch (os, arch) {
        case ("macOS", "arm64"): "pumpkin-ARM64-macOS"
        case ("linux", "arm64"): "pumpkin-ARM64-Linux"
        case ("linux", "x64"): "pumpkin-X64-Linux"
        case ("windows", "arm64"): "pumpkin-ARM64-Windows.exe"
        case ("windows", "x64"): "pumpkin-X64-Windows.exe"
        default: nil   // Pumpkin has no Intel Mac build
        }
    }

    static var currentOS: String { "macOS" }
    static var currentArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    /// `+` in a tag must be percent-encoded in a download URL.
    static func downloadURL(tag: String, file: String) -> URL? {
        let t = tag.replacingOccurrences(of: "+", with: "%2B")
        return URL(string: "\(releasesBase)/\(t)/\(file)")
    }

    /// `checksums.sha256` lines are `<64 hex>  <file name>`.
    static func parseChecksums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { continue }
            out[String(parts[1])] = parts[0].lowercased()
        }
        return out
    }

    // MARK: Where it lives

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CraftPanel/engines/pumpkin", directoryHint: .isDirectory)
    }

    static func binaryURL(tag: String, root: URL = root) -> URL {
        root.appending(path: tag, directoryHint: .isDirectory).appending(path: "pumpkin")
    }

    /// The pinned engine when installed, else the newest installed one, else nil.
    static func installedBinary(root: URL = root) -> URL? {
        let fm = FileManager.default
        let pinned = binaryURL(tag: pinnedTag, root: root)
        if fm.isExecutableFile(atPath: pinned.path) { return pinned }
        let tags = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted().reversed()
        for tag in tags {
            let b = binaryURL(tag: tag, root: root)
            if fm.isExecutableFile(atPath: b.path) { return b }
        }
        return nil
    }

    // MARK: Install

    /// Puts a downloaded file in place if (and only if) its SHA-256 is the expected one.
    /// The download is never run before this check passes.
    static func place(downloaded file: URL, expectedSHA256: String, tag: String, root: URL = root) throws -> URL {
        let actual = try sha256Hex(file)
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw ProvisionError.message("The OMNIHost engine download didn't match the checksum published with it, so OMNIServers deleted it rather than run it. Try again.")
        }
        let dest = binaryURL(tag: tag, root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: file, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        // A file saved by this app is not quarantined, but one copied in by hand may be.
        removexattr(dest.path, "com.apple.quarantine", 0)
        return dest
    }

    /// Downloads and verifies the pinned engine unless it is already installed.
    static func ensureInstalled(progress: @escaping @Sendable (ProvisionProgress) -> Void) async throws -> URL {
        if let b = installedBinary() {
            progress(ProvisionProgress(stage: "done", message: "OMNIHost engine is ready.", pct: 100))
            return b
        }
        guard let asset = assetName() else {
            throw ProvisionError.message("OMNIHost has no engine for this Mac yet (Pumpkin ships Apple Silicon builds only).")
        }
        guard let sumsURL = downloadURL(tag: pinnedTag, file: "checksums.sha256"),
              let binURL = downloadURL(tag: pinnedTag, file: asset) else {
            throw ProvisionError.message("Bad engine download address.")
        }
        progress(ProvisionProgress(stage: "fetch", message: "Finding the OMNIHost engine…", pct: nil))
        var sreq = URLRequest(url: sumsURL, timeoutInterval: 30)
        sreq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (sdata, sresp) = try await URLSession.shared.data(for: sreq)
        guard (sresp as? HTTPURLResponse)?.statusCode == 200,
              let sums = String(data: sdata, encoding: .utf8).map(parseChecksums),
              let expected = sums[asset] else {
            throw ProvisionError.message("Couldn't read the engine's checksum list from GitHub.")
        }
        progress(ProvisionProgress(stage: "download", message: "Downloading the OMNIHost engine (about 100 MB, once)…", pct: 0))
        var breq = URLRequest(url: binURL, timeoutInterval: 600)
        breq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (tmp, bresp) = try await URLSession.shared.download(for: breq)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (bresp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ProvisionError.message("Engine download failed (HTTP \((bresp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        progress(ProvisionProgress(stage: "verify", message: "Verifying checksum…", pct: nil))
        let tag = pinnedTag
        let placed = try await Task.detached { try place(downloaded: tmp, expectedSHA256: expected, tag: tag) }.value
        progress(ProvisionProgress(stage: "done", message: "OMNIHost engine installed.", pct: 100))
        return placed
    }

    private static func sha256Hex(_ url: URL) throws -> String {
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw ProvisionError.message("can't read download") }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// `pumpkin.toml`: the settings OMNIServers writes before a server's first start. Pumpkin fills
/// in every other key itself (checked: a partial file is accepted and completed).
nonisolated enum PumpkinConfig {
    static let fileName = "pumpkin.toml"

    struct Settings: Sendable, Equatable {
        var motd: String
        var port: UInt16
        var maxPlayers: Int
        var gamemode: String
        var difficulty: String
        var seed: String
        /// Mojang sign-in for players. On unless the user knowingly turns it off.
        var onlineMode: Bool = true
        /// Folder name of the world. `world` unless a transferred server used another.
        var levelName: String = "world"
        var viewDistance: Int? = nil
        var simulationDistance: Int? = nil
        var whitelist: Bool = false
        var enforceWhitelist: Bool = false
        var hardcore: Bool = false
        var allowNether: Bool = true
        var spawnProtection: Int = 16
        var forceGamemode: Bool = false
        var opPermissionLevel: Int = 4
        var pvp: Bool = true
        /// Resource pack players are offered on join (server.properties `resource-pack`).
        var resourcePackURL: String = ""
        var resourcePackSHA1: String = ""
        var resourcePackForce: Bool = false
        var resourcePackPrompt: String = ""
    }

    /// `survival` -> `Survival`: Pumpkin wants the capitalised names.
    static func titleCase(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst().lowercased()
    }

    /// A TOML basic string: quotes, backslashes and line breaks escaped.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r": out += " "
            default: out.append(c)
            }
        }
        return out + "\""
    }

    static func render(_ s: Settings) -> String {
        let players = min(max(s.maxPlayers, 1), 1000)
        var lines: [String] = []
        let seed = s.seed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seed.isEmpty { lines.append("seed = \(quoted(seed))") }
        lines.append("default_difficulty = \(quoted(titleCase(s.difficulty)))")
        lines.append("default_gamemode = \(quoted(titleCase(s.gamemode)))")
        if s.levelName != "world" { lines.append("default_level_name = \(quoted(s.levelName))") }
        if s.whitelist { lines.append("white_list = true") }
        if s.enforceWhitelist { lines.append("enforce_whitelist = true") }
        if s.hardcore { lines.append("hardcore = true") }
        if !s.allowNether { lines.append("allow_nether = false") }
        if s.spawnProtection != 16 { lines.append("spawn_protection = \(min(max(s.spawnProtection, 0), 1000))") }
        if s.forceGamemode { lines.append("force_gamemode = true") }
        if s.opPermissionLevel != 4 { lines.append("op_permission_level = \(min(max(s.opPermissionLevel, 0), 4))") }
        lines.append("favicon_path = \"\(BrandingManager.iconFile)\"")   // the OMNIHost icon, or the one the user sets
        // Pumpkin sends anonymous heartbeats to its own server by default. Off for our users.
        lines.append("")
        lines.append("[telemetry]")
        lines.append("enabled = false")
        lines.append("")
        lines.append("[logging]")
        lines.append("color = false")   // plain text in the console tab
        lines.append("")
        lines.append("[networking.java]")
        lines.append("address = \"0.0.0.0:\(s.port)\"")
        lines.append("online_mode = \(s.onlineMode)")
        // Without this the engine still asks players to encrypt, which needs a Mojang sign-in (checked).
        lines.append("encryption = \(s.onlineMode)")
        lines.append("max_players = \(players)")
        if let v = s.viewDistance { lines.append("view_distance = \(min(max(v, 2), 32))") }
        if let v = s.simulationDistance { lines.append("simulation_distance = \(min(max(v, 2), 32))") }
        lines.append("motd = \(quoted(s.motd.isEmpty ? "A Minecraft Server" : s.motd))")
        lines.append("")
        // Bedrock listens on 19132 by default. Off until there is a switch for it.
        lines.append("[networking.bedrock]")
        lines.append("enabled = false")
        if !s.pvp {
            lines.append("")
            lines.append("[pvp]")
            lines.append("enabled = false")
        }
        let pack = s.resourcePackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pack.isEmpty {
            lines.append("")
            lines.append("[resource_pack.java]")
            lines.append("enabled = true")
            lines.append("url = \(quoted(pack))")
            lines.append("sha1 = \(quoted(s.resourcePackSHA1.trimmingCharacters(in: .whitespaces)))")
            lines.append("prompt_message = \(quoted(s.resourcePackPrompt))")
            lines.append("force = \(s.resourcePackForce)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Java port in `pumpkin.toml` text (`[networking.java]` `address = "host:port"`).
    static func javaPort(in toml: String) -> UInt16? {
        var inJava = false
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inJava = (line == "[networking.java]"); continue }
            guard inJava, line.hasPrefix("address") else { continue }
            guard let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") else { return nil }
            let addr = line[line.index(after: q1)..<q2]
            guard let colon = addr.lastIndex(of: ":"), let p = UInt16(addr[addr.index(after: colon)...]), p != 0 else { return nil }
            return p
        }
        return nil
    }

    static func javaPort(serverDir: URL) -> UInt16? {
        guard let t = try? String(contentsOf: serverDir.appending(path: fileName), encoding: .utf8) else { return nil }
        return javaPort(in: t)
    }

    // MARK: Editing an existing file

    /// What Settings can change on a server. Everything else in `pumpkin.toml` is left alone.
    struct Editable: Sendable, Equatable {
        var onlineMode: Bool
        var motd: String
        var maxPlayers: Int
        var gamemode: String
        var difficulty: String
    }

    private static let javaSection = "networking.java"

    private static func headerName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]"), !t.hasPrefix("[[") else { return nil }
        return String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func keyName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces)
    }

    /// The raw text after `key =` in `section` ("" is the top of the file), without a trailing comment.
    static func rawValue(in toml: String, section: String, key: String) -> String? {
        var current = ""
        for line in toml.components(separatedBy: "\n") {
            if let h = headerName(line) { current = h; continue }
            guard current == section, keyName(line) == key, let eq = line.firstIndex(of: "=") else { continue }
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !v.hasPrefix("\""), let hash = v.firstIndex(of: "#") { v = v[..<hash].trimmingCharacters(in: .whitespaces) }
            return v
        }
        return nil
    }

    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        var out = "", escaped = false
        for c in raw.dropFirst().dropLast() {
            if escaped { out.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else { out.append(c) }
        }
        return out
    }

    /// `toml` with `key = raw` set in `section`: the line is replaced where it is, or added at the end of
    /// the section (or the section is added). Every other line stays byte for byte.
    static func setting(in toml: String, section: String, key: String, raw: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        var current = "", sectionStart: Int? = nil, lastInSection: Int? = nil
        for (i, line) in lines.enumerated() {
            if let h = headerName(line) {
                current = h
                if h == section { sectionStart = i; lastInSection = i }
                continue
            }
            guard current == section else { continue }
            if keyName(line) == key { lines[i] = "\(key) = \(raw)"; return lines.joined(separator: "\n") }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastInSection = i }
        }
        let entry = "\(key) = \(raw)"
        if section.isEmpty {
            // Top-level keys must come before the first [section].
            let firstHeader = lines.firstIndex { headerName($0) != nil } ?? lines.count
            lines.insert(entry, at: firstHeader)
        } else if sectionStart != nil, let last = lastInSection {
            lines.insert(entry, at: last + 1)
        } else {
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += ["", "[\(section)]", entry, ""]
        }
        return lines.joined(separator: "\n")
    }

    static func read(serverDir: URL) -> Editable? {
        guard let t = try? String(contentsOf: serverDir.appending(path: fileName), encoding: .utf8) else { return nil }
        return read(toml: t)
    }

    static func read(toml t: String) -> Editable {
        let online = rawValue(in: t, section: javaSection, key: "online_mode") ?? "true"
        return Editable(
            onlineMode: online != "false",
            motd: rawValue(in: t, section: javaSection, key: "motd").map(unquote) ?? "",
            maxPlayers: rawValue(in: t, section: javaSection, key: "max_players").flatMap { Int($0) } ?? 20,
            gamemode: (rawValue(in: t, section: "", key: "default_gamemode").map(unquote) ?? "Survival").lowercased(),
            difficulty: (rawValue(in: t, section: "", key: "default_difficulty").map(unquote) ?? "Normal").lowercased())
    }

    /// Writes the editable settings into the server's `pumpkin.toml`.
    static func apply(_ e: Editable, serverDir: URL) throws {
        let url = serverDir.appending(path: fileName)
        var t = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        t = setting(in: t, section: javaSection, key: "online_mode", raw: e.onlineMode ? "true" : "false")
        t = setting(in: t, section: javaSection, key: "encryption", raw: e.onlineMode ? "true" : "false")
        t = setting(in: t, section: javaSection, key: "motd", raw: quoted(e.motd.isEmpty ? "A Minecraft Server" : e.motd))
        t = setting(in: t, section: javaSection, key: "max_players", raw: String(min(max(e.maxPlayers, 1), 1000)))
        t = setting(in: t, section: "", key: "default_gamemode", raw: quoted(titleCase(e.gamemode)))
        t = setting(in: t, section: "", key: "default_difficulty", raw: quoted(titleCase(e.difficulty)))
        try t.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Servers made before the OMNIHost icon existed: point the favicon at `server-icon.png`.
    static func ensureFavicon(serverDir: URL) {
        let url = serverDir.appending(path: fileName)
        guard let t = try? String(contentsOf: url, encoding: .utf8),
              rawValue(in: t, section: "", key: "favicon_path") == nil else { return }
        try? setting(in: t, section: "", key: "favicon_path", raw: quoted(BrandingManager.iconFile))
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
