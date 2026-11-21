import Foundation

/// Result of scanning a folder: the flavour plus any extra facts the UI
/// shows in the "confirm" step of the Add Server flow. Mirrors
/// `minecraft::MinecraftDetection`.
struct MinecraftDetection: Codable, Sendable {
    var serverType: ServerType
    /// Jar or run-script the launcher should invoke, relative to the folder.
    var launchTarget: String
    /// Best-effort Minecraft version string (e.g. "1.20.4" or "26.2"),
    /// if one could be found.
    var mcVersion: String?
    /// Files matched on, for display / debugging in the UI.
    var evidence: [String]
}

/// Minecraft (Java Edition) implementation of `ServerAdapter`. Detection
/// precedence is load-bearing and intentional, ported exactly from
/// `minecraft.rs`: Fabric/Quilt must win over a bare `server.jar` check,
/// because a modern Fabric install keeps the vanilla jar sitting right
/// next to its own launcher jar — checking Vanilla first would
/// misidentify every Fabric server as Vanilla.
/// `nonisolated` because it's stateless — pure functions over a path and
/// a config. Without this, the file's default MainActor isolation would
/// make even constructing one from a background context a warning.
nonisolated struct MinecraftAdapter: ServerAdapter {

    // MARK: Detection

    /// Full scan used by the Add Server flow. Only scans the top level
    /// of `path` — a plugin/mod living in a subfolder is out of scope by
    /// construction, so `jarMatching` doesn't need to guard against that
    /// separately.
    static func inspect(at path: URL) -> MinecraftDetection? {
        let entries = listFiles(at: path)
        let has: (String) -> Bool = { name in
            entries.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        let findGlob: (String, String) -> String? = { prefix, suffix in
            entries.first {
                let l = $0.lowercased()
                return l.hasPrefix(prefix) && l.hasSuffix(suffix)
            }
        }

        var evidence: [String] = []

        // --- Fabric / Quilt --------------------------------------------
        // Any one marker is enough, and this MUST run before the generic
        // server.jar check below.
        do {
            let launchJar: String? =
                has("fabric-server-launch.jar") ? "fabric-server-launch.jar" :
                has("quilt-server-launch.jar") ? "quilt-server-launch.jar" :
                findGlob("fabric-server", ".jar") ?? findGlob("quilt-server", ".jar")

            let props = has("fabric-server-launcher.properties")
            let fabricDir = isDirectory(path.appending(path: ".fabric"))
                || isDirectory(path.appending(path: ".quilt"))
            let fabricLibs = isDirectory(path.appending(path: "libraries/net/fabricmc"))
                || isDirectory(path.appending(path: "libraries/org/quiltmc"))

            if launchJar != nil || props || fabricDir || fabricLibs {
                if let j = launchJar { evidence.append(j) }
                if props { evidence.append("fabric-server-launcher.properties") }
                if fabricDir { evidence.append(".fabric/") }
                if fabricLibs { evidence.append("libraries/net/fabricmc") }

                let target = launchJar ?? "fabric-server-launch.jar"
                return MinecraftDetection(
                    serverType: .fabric,
                    launchTarget: target,
                    mcVersion: detectVersion(at: path, entries: entries),
                    evidence: evidence
                )
            }
        }

        // --- Forge / NeoForge -------------------------------------------
        let hasForgeRun = has("run.sh") || has("run.bat")
        let forgeJar = findGlob("forge-", ".jar") ?? findGlob("neoforge-", ".jar")
        let hasForgeLibs = isDirectory(path.appending(path: "libraries/net/minecraftforge"))
            || isDirectory(path.appending(path: "libraries/net/neoforged"))

        if hasForgeRun || forgeJar != nil || hasForgeLibs {
            let target: String =
                has("run.sh") ? "run.sh" :
                has("run.bat") ? "run.bat" :
                forgeJar ?? "run.sh"

            if hasForgeRun { evidence.append("run script") }
            if let j = forgeJar { evidence.append(j) }
            if hasForgeLibs { evidence.append("libraries/net/minecraftforge") }

            let isNeo = findGlob("neoforge-", ".jar") != nil
                || isDirectory(path.appending(path: "libraries/net/neoforged"))
            return MinecraftDetection(
                serverType: isNeo ? .neoforge : .forge,
                launchTarget: target,
                mcVersion: detectVersion(at: path, entries: entries),
                evidence: evidence
            )
        }

        // --- Paper --------------------------------------------------
        if let jar = jarMatching(entries, key: "paper") {
            evidence.append(jar)
            return MinecraftDetection(
                serverType: .paper,
                launchTarget: jar,
                mcVersion: detectVersion(at: path, entries: entries),
                evidence: evidence
            )
        }

        // --- Spigot / Bukkit / CraftBukkit --------------------------
        for key in ["spigot", "craftbukkit", "bukkit"] {
            if let jar = jarMatching(entries, key: key) {
                evidence.append(jar)
                return MinecraftDetection(
                    serverType: .spigot,
                    launchTarget: jar,
                    mcVersion: detectVersion(at: path, entries: entries),
                    evidence: evidence
                )
            }
        }

        // --- Vanilla / generic ---------------------------------------
        if has("server.jar") {
            evidence.append("server.jar")
            return MinecraftDetection(
                serverType: .vanilla,
                launchTarget: "server.jar",
                mcVersion: detectVersion(at: path, entries: entries),
                evidence: evidence
            )
        }
        // Last resort: a lone jar that isn't obviously a mod/plugin.
        let jars = entries.filter { $0.lowercased().hasSuffix(".jar") }
        if jars.count == 1, let only = jars.first {
            evidence.append(only)
            return MinecraftDetection(
                serverType: .vanilla,
                launchTarget: only,
                mcVersion: detectVersion(at: path, entries: entries),
                evidence: evidence
            )
        }

        return nil
    }

    static func detect(at path: URL) -> ServerType? {
        inspect(at: path)?.serverType
    }

    // MARK: Launch

    /// Direct port of `process.rs`'s `build_command` (the Java branch —
    /// Bedrock is its own adapter in Swift). A Forge/NeoForge server
    /// installed via the modern installer ships no runnable jar at all,
    /// only `run.sh`/`run.bat` plus an args file under
    /// `libraries/net/{minecraftforge/forge,neoforged/neoforge}/<ver>/` —
    /// launching that with `-jar run.sh` is a real crash, not a
    /// simplification, so this checks for the args file first exactly
    /// like the Rust source does.
    func startCommand(config: ServerConfig) -> Process {
        let process = Process()
        process.executableURL = Self.resolveExecutable(config.javaPath)
        process.currentDirectoryURL = config.path

        if config.serverType.isForgeFamily, let argFile = Self.forgeArgsFile(dir: config.path) {
            // JVM heap flags come from user_jvm_args.txt, written by
            // `ensureUserJVMArgs` before this is called.
            process.arguments = ["@user_jvm_args.txt", "@\(argFile)", "nogui"]
            return process
        }

        var args = ["-Xms\(Self.initialHeapMB(config.ramMB))M", "-Xmx\(config.ramMB)M"]
        args.append(contentsOf: Self.jvmArgTokens(config.jvmArgs))
        args.append(contentsOf: ["-jar", config.launchTarget, "nogui"])
        process.arguments = args
        return process
    }

    /// Start small and grow on demand: with -Xms equal to -Xmx (the
    /// dedicated-host convention) Java claims the whole allocation from
    /// macOS the moment it starts, even with nobody online — an 8 GB
    /// server showed 8 GB in Activity Monitor at idle. -Xmx stays the cap.
    static func initialHeapMB(_ ramMB: UInt32) -> UInt32 { min(ramMB, 1024) }

    /// Whitespace-split extra JVM flags, keeping only tokens that look
    /// like flags (`-Xmx…`, `-XX:…`, etc.) — matches `jvm_arg_tokens`.
    static func jvmArgTokens(_ jvmArgs: String?) -> [String] {
        (jvmArgs ?? "").split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.hasPrefix("-") }
    }

    /// Path (relative to the server dir, forward slashes) to the
    /// platform args file inside a modern Forge/NeoForge install, if one
    /// exists. Matches `forge_args_file` exactly.
    static func forgeArgsFile(dir: URL) -> String? {
        let file = "unix_args.txt" // macOS only — no `win_args.txt` branch needed here
        let fm = FileManager.default
        for base in ["libraries/net/minecraftforge/forge", "libraries/net/neoforged/neoforge"] {
            let root = dir.appendingPathComponent(base)
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let candidate = entry.appendingPathComponent(file)
                if fm.fileExists(atPath: candidate.path) {
                    // Built from known components rather than stripping
                    // `dir`'s prefix off the resolved URL — `/tmp` vs
                    // `/private/tmp` symlink normalization can make the
                    // two sides disagree even though they name the same
                    // file, which a string-prefix check would miss.
                    return "\(base)/\(entry.lastPathComponent)/\(file)"
                }
            }
        }
        return nil
    }

    /// Ensures `-Xms`/`-Xmx` (and any extra flags) land even when launch
    /// goes through a Forge args file, which reads JVM flags from
    /// `user_jvm_args.txt` rather than argv. Matches `ensure_user_jvm_args`:
    /// strips any previously-written heap/extra flags, keeps everything
    /// else the user (or the Forge installer) put there, re-appends fresh.
    static func ensureUserJVMArgs(config: ServerConfig) {
        guard config.serverType.isForgeFamily, forgeArgsFile(dir: config.path) != nil else { return }
        let path = config.path.appendingPathComponent("user_jvm_args.txt")
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let extra = jvmArgTokens(config.jvmArgs)

        let kept = existing.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            guard !t.hasPrefix("-Xmx"), !t.hasPrefix("-Xms") else { return false }
            return !extra.contains { $0 == t.trimmingCharacters(in: .whitespaces) }
        }

        var out = kept.joined(separator: "\n")
        if !out.isEmpty, !out.hasSuffix("\n") { out.append("\n") }
        out += "-Xms\(initialHeapMB(config.ramMB))M\n-Xmx\(config.ramMB)M\n"
        for t in extra { out += "\(t)\n" }
        try? out.write(to: path, atomically: true, encoding: .utf8)
    }

    /// `Process.executableURL` needs a real path, not a bare command name
    /// the way `std::process::Command::new("java")` can resolve off
    /// PATH — Foundation doesn't do PATH lookup for you. Shared with
    /// `JavaProbe`.
    static func resolveExecutable(_ exe: String) -> URL {
        if exe.hasPrefix("/") { return URL(fileURLWithPath: exe) }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = URL(fileURLWithPath: String(dir)).appending(path: exe)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // fall back to the bare name — `Process.run()` throws a clear
        // "executable not found" error at launch time rather than here
        return URL(fileURLWithPath: exe)
    }

    // MARK: Console parsing

    func parseStatus(output: String) -> ServerStatus {
        let o = output.lowercased()
        if o.contains("done (") && o.contains("for help") {
            return .running
        } else if o.contains("starting minecraft server") || o.contains("loading properties") {
            return .starting
        } else if o.contains("stopping the server") || o.contains("stopping server") {
            return .stopping
        } else if o.contains("exception in server tick loop") || o.contains("failed to start") {
            return .crashed
        }
        return .unknown
    }

    // MARK: - Private helpers

    static func listFiles(at path: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// A jar whose filename contains `key`. Only the top level is ever
    /// scanned, so "not a plugin sitting in a subfolder" is guaranteed
    /// by construction, same as the Rust source.
    private static func jarMatching(_ entries: [String], key: String) -> String? {
        entries.first {
            let l = $0.lowercased()
            return l.hasSuffix(".jar") && l.contains(key)
        }
    }

    /// Best-effort Minecraft version discovery, checked in the same
    /// priority order as `minecraft::detect_version`.
    private static func detectVersion(at path: URL, entries: [String]) -> String? {
        // 1. Paper/Purpur's version_history.json: "... (MC: 1.20.4)".
        if let text = try? String(contentsOf: path.appending(path: "version_history.json"), encoding: .utf8),
           let v = extractMCParen(text) {
            return v
        }
        // 2. Fabric's launcher properties.
        if let text = try? String(contentsOf: path.appending(path: "fabric-server-launcher.properties"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if line.hasPrefix("serverJar="), let v = extractVersionToken(String(line.dropFirst("serverJar=".count))) {
                    return v
                }
            }
        }
        // 3. A jar filename that carries the version, e.g. minecraft_server.1.20.4.jar
        for e in entries {
            if let v = extractVersionToken(e) { return v }
        }
        // 4. Forge libraries dir: libraries/net/minecraft/server/<mcver>-<forgever>/
        let serverLibs = path.appending(path: "libraries/net/minecraft/server")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: serverLibs.path) {
            for name in names {
                if let v = extractVersionToken(name) { return v }
            }
        }
        // 5. Fabric/Vanilla keep the real server jar under versions/<ver>/
        let versionsDir = path.appending(path: "versions")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path) {
            for name in names where isMCVersion(name) {
                return name
            }
        }
        return nil
    }

    private static func extractMCParen(_ text: String) -> String? {
        guard let range = text.range(of: "(MC:") else { return nil }
        let tail = text[range.upperBound...]
        guard let end = tail.firstIndex(of: ")") else { return nil }
        let v = tail[..<end].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// Pull a Minecraft version token out of an arbitrary string.
    ///
    /// Handles both schemes: the classic `1.x` / `1.x.y` and the
    /// year-based scheme Mojang moved to in 2026 (`26.0`, `26.2`, `27.1`,
    /// …). Won't match a bare integer or a `0.x` — needs a plausible MC
    /// major (1, or 20–99), same guard as the Rust source, which is what
    /// keeps a Fabric loader build number like `0.16.5` from being
    /// mistaken for a Minecraft version.
    static func extractVersionToken(_ s: String) -> String? {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i].isASCII, chars[i].isNumber, (i == 0 || !(chars[i - 1].isASCII && chars[i - 1].isNumber)) {
                let start = i
                var j = i
                while j < chars.count, (chars[j].isNumber && chars[j].isASCII) || chars[j] == "." {
                    j += 1
                }
                var tok = String(chars[start..<j])
                while tok.hasSuffix(".") { tok.removeLast() }
                if isMCVersion(tok) { return tok }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }

    /// `1.x[.y]` (classic) or `<20...99>.x[.y]` (year scheme).
    static func isMCVersion(_ tok: String) -> Bool {
        let parts = tok.split(separator: ".")
        guard (2...3).contains(parts.count) else { return false }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        guard let major = Int(parts[0]) else { return false }
        return major == 1 || (20...99).contains(major)
    }
}
