import Foundation

/// Mirrors `java::JavaInfo` exactly.
struct JavaInfo: Codable, Sendable, Equatable {
    /// Executable probed (`java`, or an absolute path).
    var path: String
    /// Raw first line of `java -version`.
    var raw: String
    /// Parsed feature version: 8, 11, 17, 21, ...
    var major: UInt32
    /// "64-Bit" present in the banner.
    var is64Bit: Bool
}

/// Java runtime detection and Minecraft-version compatibility checks.
/// Mirrors `java.rs` exactly — same parsing rules, same required-Java
/// table, same "silently return nil on any failure" contract as the
/// Rust source's `.ok()?` chain (a Java probe failing is an expected,
/// common outcome — no JDK installed yet — not an exceptional one).
nonisolated enum JavaProbe {

    /// Probe a Java executable. `exe` defaults to `java` resolved off
    /// PATH. `async` because launching and waiting on a subprocess is
    /// inherently a blocking operation — callers (the Add Server flow,
    /// the periodic doctor check) should never do this on the main actor.
    static func probe(exe: String? = nil) async -> JavaInfo? {
        let exe = exe ?? "java"
        // Off the main actor, both pipes drained concurrently, bounded wait
        // (a broken JDK shim that never exits used to freeze the UI).
        let url = MinecraftAdapter.resolveExecutable(exe)
        // /usr/bin/java is Apple's stub: with no JDK installed it pops an
        // "install Java" dialog. Ask the JVM registry first instead.
        if url.path == "/usr/bin/java" {
            guard let r = try? await Subprocess.runAsync("/usr/libexec/java_home", [], timeout: 10), r.status == 0 else { return nil }
        }
        guard let r = try? await Subprocess.runAsync(url.path, ["-version"], timeout: 15), !r.timedOut else {
            return nil // no such executable — the common, expected case
        }
        let stderrData = r.stderr
        let stdoutData = r.stdout

        // `java -version` prints to stderr — a real, easy-to-miss gotcha
        // (most CLI tools print version info to stdout) preserved exactly
        // from the Rust source.
        let text = !stderrData.isEmpty
            ? String(decoding: stderrData, as: UTF8.self)
            : String(decoding: stdoutData, as: UTF8.self)

        guard let major = parseMajor(text) else { return nil }
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        return JavaInfo(path: exe, raw: first, major: major, is64Bit: text.contains("64-Bit"))
    }

    /// Parse the feature version out of a `java -version` banner.
    ///
    /// `openjdk version "1.8.0_361"`   -> 8
    /// `openjdk version "17.0.8"`      -> 17
    /// `java version "21" 2023-09-19`  -> 21
    static func parseMajor(_ text: String) -> UInt32? {
        guard let firstQuote = text.firstIndex(of: "\"") else { return nil }
        let rest = text[text.index(after: firstQuote)...]
        guard let secondQuote = rest.firstIndex(of: "\"") else { return nil }
        let ver = rest[..<secondQuote]
        var parts = ver.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })[...]
        guard let first = parts.first else { return nil }
        parts.removeFirst()
        if first == "1" {
            guard let second = parts.first else { return nil }
            return UInt32(second)
        }
        return UInt32(first)
    }

    /// Find an installed runtime of exactly `required` — OMNIServers's own
    /// managed JRE first, then the OS JVM registry (`/usr/libexec/java_home`,
    /// which knows Adoptium/Oracle/Homebrew/SDKMAN installs). Every
    /// candidate is verified with a real probe. Port of `find_compatible_java`.
    static func findCompatibleJava(required: UInt32) async -> String? {
        if let f = JavaInstaller.offerableFeature(requiredJava: required),
           let p = JavaInstaller.installedPath(feature: f),
           let info = await probe(exe: p), info.major == required {
            return p
        }
        for spec in ["\(required)", "1.\(required)"] {
            guard let r = try? await Subprocess.runAsync("/usr/libexec/java_home", ["-v", spec], timeout: 10),
                  r.status == 0 else { continue }
            let home = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !home.isEmpty else { continue }
            let candidate = home + "/bin/java"
            if let info = await probe(exe: candidate), info.major == required { return candidate }
        }
        return nil
    }

    /// Synchronous, cheap pick used right before a launch: when a server is
    /// set to the generic `java` (or a path that no longer exists), return a
    /// matching CraftPanel-managed runtime, else `java_home -v <need>`.
    /// nil = leave the configured value alone.
    static func autoResolve(javaPath: String, mcVersion: String?) -> String? {
        let generic = javaPath == "java" || javaPath.isEmpty
        let missing = javaPath.hasPrefix("/") && !FileManager.default.isExecutableFile(atPath: javaPath)
        guard generic || missing, let mc = mcVersion else { return nil }
        let need = requiredJava(forMC: mc)
        // Managed runtimes: exact major first, then any newer one we have.
        for f: UInt8 in [UInt8(need), 17, 21, 25].filter({ UInt32($0) >= need }) {
            if JavaInstaller.offerableFeature(requiredJava: UInt32(f)) != nil, let p = JavaInstaller.installedPath(feature: f) { return p }
        }
        if let r = try? Subprocess.run("/usr/libexec/java_home", ["-v", "\(need)+"], timeout: 5), r.status == 0 {
            let home = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !home.isEmpty { return home + "/bin/java" }
        }
        return nil
    }

    /// Every JVM the OS knows about plus CraftPanel-managed ones, probed.
    static func listRuntimes() async -> [JavaInfo] {
        var homes: [String] = []
        if let r = try? await Subprocess.runAsync("/usr/libexec/java_home", ["-X"], timeout: 10), r.status == 0,
           let plist = try? PropertyListSerialization.propertyList(from: r.stdout, format: nil) as? [[String: Any]] {
            homes += plist.compactMap { $0["JVMHomePath"] as? String }.map { $0 + "/bin/java" }
        }
        for f: UInt8 in [17, 21, 25] { if let p = JavaInstaller.installedPath(feature: f) { homes.append(p) } }
        var out: [JavaInfo] = []
        for h in Set(homes).sorted() { if let i = await probe(exe: h) { out.append(i) } }
        return out.sorted { $0.major > $1.major }
    }

    /// Minimum Java feature version Mojang requires for a given MC version.
    static func requiredJava(forMC mcVersion: String) -> UInt32 {
        let (major, minor, patch) = parseMC(mcVersion)
        if major != 1 {
            // Mojang's year-based scheme (e.g. "26.1") replaced "1.x"
            // starting with 2026 releases — 26.0 and up ship needing
            // Java 25+, not 21.
            return major >= 26 ? 25 : 21
        }
        switch minor {
        case 0...16: return 8
        case 17: return 16
        case 18...19: return 17
        case 20: return patch <= 4 ? 17 : 21 // 1.20.5+
        default: return 21 // 1.21+
        }
    }

    /// Human-readable compatibility note, or `nil` if the pairing is fine.
    static func compatibilityWarning(java: JavaInfo, mcVersion: String?) -> String? {
        guard let mc = mcVersion else { return nil }
        let need = requiredJava(forMC: mc)
        if java.major < need {
            return "Minecraft \(mc) needs Java \(need)+, but the detected runtime is Java \(java.major). " +
                   "The server will fail to start until you install a newer JDK."
        } else if java.major > need + 4, need <= 8 {
            return "Minecraft \(mc) expects Java \(need). Java \(java.major) usually still works but is untested by Mojang for this version."
        }
        return nil
    }

    private static func parseMC(_ v: String) -> (UInt32, UInt32, UInt32) {
        let parts = v.trimmingCharacters(in: .whitespaces).split(separator: ".").map { part -> UInt32 in
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            return UInt32(digits) ?? 0
        }
        return (parts.count > 0 ? parts[0] : 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }
}
