import Foundation
import CryptoKit

/// Create a server from scratch: pick loader + version, download the
/// artifact, first-boot it to generate configs, accept the EULA. Direct
/// port of `provision.rs`'s create flow.
///
/// **Scope of this pass, stated plainly rather than faked**: Vanilla,
/// Paper, Fabric, Forge, and NeoForge. Two things `provision.rs` also
/// covers are deliberately not here yet:
/// - **Bedrock provisioning** — the Rust source's own comment says it
///   straight out: "Windows/Linux only; no macOS build exists." Nothing
///   to port on this platform.
/// - **Modpack (.mrpack) install** — a real, separate chunk of work
///   (zip parsing, the mrpack manifest format, overrides extraction);
///   flagged as the next follow-up rather than squeezed in half-done.
///
/// Java auto-install (`javainstall.rs`) isn't ported either — the wizard
/// requires an already-installed Java, same as Add Existing Server does.
nonisolated enum Loader: String, CaseIterable, Sendable, Identifiable {
    case vanilla, paper, fabric, neoforge, forge
    var id: String { rawValue }

    var serverType: ServerType {
        switch self {
        case .vanilla: .vanilla
        case .paper: .paper
        case .fabric: .fabric
        case .neoforge: .neoforge
        case .forge: .forge
        }
    }

    var label: String {
        switch self {
        case .vanilla: "Vanilla"
        case .paper: "Paper"
        case .fabric: "Fabric"
        case .neoforge: "NeoForge"
        case .forge: "Forge"
        }
    }
}

nonisolated struct VersionInfo: Sendable, Identifiable, Equatable {
    var id: String
    /// "release" | "snapshot" | "beta" | ...
    var kind: String
}

nonisolated struct CreateSpec: Sendable {
    var loader: Loader
    var mcVersion: String
    /// loader build (Fabric loader, NeoForge/Forge version); ignored for vanilla/paper.
    var loaderVersion: String?
    var dir: URL
    var name: String
    var ramMB: UInt32
    var javaPath: String?
    var seed: String?
    var gamemode: String?
    var difficulty: String?
    var motd: String?
    var maxPlayers: UInt32?
}

nonisolated struct ProvisionProgress: Sendable {
    var stage: String
    var message: String
    /// 0...100 when known.
    var pct: Int?
}

nonisolated struct Created: Sendable {
    var serverType: ServerType
    var launchTarget: String
    var mcVersion: String
    var dir: URL
    /// The Java actually used — may be an auto-picked compatible JDK.
    var javaPath: String
}

nonisolated enum ProvisionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}

/// Watches first-boot console lines for the two things that matter —
/// "done, ready" and "the EULA needs accepting" — from a background
/// pipe-readability callback. An actor rather than a plain flag pair
/// because that callback fires on an arbitrary queue.
private actor BootWatch {
    private(set) var ready = false
    private(set) var eulaBlocked = false

    func observe(_ line: String) {
        let l = line.lowercased()
        if l.contains("done (") && l.contains("for help") { ready = true }
        if l.contains("you need to agree to the eula") { eulaBlocked = true }
    }
}

nonisolated enum Provisioner {
    private static let userAgent = "CraftPanel/0.1 (+https://github.com/) server-manager"
    private static let firstBootTimeout: TimeInterval = 240

    // MARK: - Version listing

    static func listVersions(_ loader: Loader) async throws -> [VersionInfo] {
        switch loader {
        case .vanilla: return try await mojangVersions()
        case .paper: return try await paperVersions()
        case .fabric: return try await fabricGameVersions()
        case .neoforge: return try await neoforgeVersions()
        case .forge: return try await forgeVersions()
        }
    }

    static func getJSON(_ urlString: String) async throws -> Any {
        guard let url = URL(string: urlString) else { throw ProvisionError.message("bad URL") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProvisionError.message("\(urlString): \(error.localizedDescription)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ProvisionError.message("\(urlString): bad JSON")
        }
        return json
    }

    private static func mojangVersions() async throws -> [VersionInfo] {
        let v = try await getJSON("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
        guard let obj = v as? [String: Any], let arr = obj["versions"] as? [[String: Any]] else {
            throw ProvisionError.message("no versions array")
        }
        return arr.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            return VersionInfo(id: id, kind: e["type"] as? String ?? "release")
        }
    }

    private static func paperVersions() async throws -> [VersionInfo] {
        let v = try await getJSON("https://fill.papermc.io/v3/projects/paper")
        guard let obj = v as? [String: Any], let families = obj["versions"] as? [String: Any] else {
            throw ProvisionError.message("no versions map")
        }
        var out: [VersionInfo] = []
        for list in families.values {
            guard let arr = list as? [String] else { continue }
            for s in arr {
                out.append(VersionInfo(id: s, kind: s.contains("-") ? "snapshot" : "release"))
            }
        }
        return out
    }

    private static func fabricGameVersions() async throws -> [VersionInfo] {
        let v = try await getJSON("https://meta.fabricmc.net/v2/versions/game")
        guard let arr = v as? [[String: Any]] else { throw ProvisionError.message("expected array") }
        return arr.compactMap { e in
            guard let id = e["version"] as? String else { return nil }
            return VersionInfo(id: id, kind: (e["stable"] as? Bool ?? false) ? "release" : "snapshot")
        }
    }

    private static func neoforgeVersions() async throws -> [VersionInfo] {
        let v = try await getJSON("https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge")
        guard let obj = v as? [String: Any], let arr = obj["versions"] as? [String] else {
            throw ProvisionError.message("no versions")
        }
        return arr.reversed().map { s in
            VersionInfo(id: s, kind: s.contains("beta") ? "beta" : "release")
        }
    }

    private static func forgeVersions() async throws -> [VersionInfo] {
        let v = try await getJSON("https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")
        guard let obj = v as? [String: Any], let promos = obj["promos"] as? [String: Any] else {
            throw ProvisionError.message("no promos")
        }
        var out: [VersionInfo] = []
        for (k, val) in promos {
            let mc: String?
            let isRecommended: Bool
            if let stripped = k.hasSuffix("-recommended") ? String(k.dropLast("-recommended".count)) : nil {
                mc = stripped; isRecommended = true
            } else if let stripped = k.hasSuffix("-latest") ? String(k.dropLast("-latest".count)) : nil {
                mc = stripped; isRecommended = false
            } else {
                mc = nil; isRecommended = false
            }
            guard let mc, let forge = val as? String else { continue }
            out.append(VersionInfo(id: "\(mc)-\(forge)", kind: isRecommended ? "release" : "beta"))
        }
        return out
    }

    /// Forge "1.20.1-47.2.0" -> "1.20.1" (MC version is the prefix).
    /// NeoForge "21.1.172" -> "1.21.1"; year-scheme "26.2.5" -> "26.2".
    /// Direct port of `deriveMcVersion` — the wizard shows Forge/NeoForge's
    /// own raw version list as the single version picker (there's no
    /// separate MC-version step for those two loaders), and this is how
    /// it recovers the MC version to display and to send as `mcVersion`.
    static func deriveMcVersion(loader: Loader, versionID: String) -> String {
        switch loader {
        case .forge:
            return versionID.split(separator: "-", maxSplits: 1).first.map(String.init) ?? versionID
        case .neoforge:
            let parts = versionID.split(separator: ".")
            guard parts.count >= 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return versionID }
            // 20.x/21.x are Minecraft 1.20.x/1.21.x ("21.0.x" is plain 1.21); the year scheme
            // (26.x and later) is the Minecraft version itself. Anything lower (snapshots) stays as is.
            if a >= 26 { return "\(a).\(b)" }
            if a >= 20 { return b == 0 ? "1.\(a)" : "1.\(a).\(b)" }
            return versionID
        default:
            return versionID
        }
    }

    // MARK: - Creation

    static func create(_ spec: CreateSpec, progress: @escaping (ProvisionProgress) -> Void) async throws -> Created {
        let dir = spec.dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path), !entries.isEmpty {
            throw ProvisionError.message("That folder isn't empty — pick a fresh folder for a new server.")
        }
        var java = spec.javaPath?.isEmpty == false ? spec.javaPath! : "java"
        // Improvement over the Rust app (which only did this for Spigot's
        // BuildTools): if the configured Java is the generic `java` and it's
        // the wrong major for this MC version, use a matching installed JDK.
        let need = JavaProbe.requiredJava(forMC: spec.mcVersion)
        java = try await ensureJava(java, need: need, mcVersion: spec.mcVersion, progress: progress)

        let serverType: ServerType
        let launchTarget: String
        switch spec.loader {
        case .vanilla:
            serverType = .vanilla
            launchTarget = try await downloadVanilla(spec, dir: dir, progress: progress)
        case .paper:
            serverType = .paper
            launchTarget = try await downloadPaper(spec, dir: dir, progress: progress)
        case .fabric:
            serverType = .fabric
            launchTarget = try await downloadFabric(spec, dir: dir, progress: progress)
        case .neoforge, .forge:
            serverType = spec.loader.serverType
            launchTarget = try await runInstaller(spec, dir: dir, java: java, progress: progress)
        }

        progress(ProvisionProgress(stage: "eula", message: "Accepting the Minecraft EULA", pct: nil))
        try "# Accepted via OMNIServers — https://aka.ms/MinecraftEULA\neula=true\n"
            .write(to: dir.appending(path: "eula.txt"), atomically: true, encoding: .utf8)

        try await firstBoot(spec, dir: dir, java: java, launchTarget: launchTarget, serverType: serverType, progress: progress)

        return Created(serverType: serverType, launchTarget: launchTarget, mcVersion: spec.mcVersion, dir: dir, javaPath: java)
    }

    /// The configured Java if it's new enough; else a matching installed JDK;
    /// else (improvement over Rust, which stopped with an error) download a
    /// verified Temurin runtime so creating a server just works.
    static func ensureJava(_ java: String, need: UInt32, mcVersion: String,
                           progress: @escaping (ProvisionProgress) -> Void) async throws -> String {
        if let cur = await JavaProbe.probe(exe: java), cur.major >= need { return java }
        if let found = await JavaProbe.findCompatibleJava(required: need) {
            progress(ProvisionProgress(stage: "java", message: "Using the installed Java \(need) runtime for Minecraft \(mcVersion).", pct: nil))
            return found
        }
        guard let f = JavaInstaller.offerableFeature(requiredJava: need) else {
            throw ProvisionError.message("Minecraft \(mcVersion) needs Java \(need), which isn't installed and can't be auto-installed on this Mac.")
        }
        progress(ProvisionProgress(stage: "java", message: "Installing Java \(f) (needed for Minecraft \(mcVersion))…", pct: nil))
        return try await JavaInstaller.install(feature: f, progress: progress).path
    }

    // MARK: - Starting settings + unique port (port of create_server's props block)

    /// First free port in 25565..<25665 not used by another known server and
    /// actually bindable — `pick_free_port`.
    static func pickFreePort(taken: Set<UInt16>) -> UInt16? {
        (UInt16(25565)..<25665).first { !taken.contains($0) && Doctor.portFree($0) }
    }

    /// Line-preserving; never touches online-mode. Bedrock has no query/RCON
    /// and calls its MOTD `server-name`.
    static func applyStartingSettings(dir: URL, bedrock: Bool, port: UInt16?, seed: String?, gamemode: String?,
                                      difficulty: String?, motd: String?, maxPlayers: UInt32?) {
        var props = Properties.load(dir: dir)
        guard FileManager.default.fileExists(atPath: dir.appending(path: "server.properties").path) else { return }
        if let port {
            _ = props.set("server-port", String(port))
            if !bedrock {
                _ = props.set("query.port", String(port))
                _ = props.set("rcon.port", String(port + 10))
            }
        }
        if let s = seed?.trimmingCharacters(in: .whitespaces), !s.isEmpty { _ = props.set("level-seed", s) }
        if let g = gamemode, ["survival", "creative", "adventure", "spectator"].contains(g) { _ = props.set("gamemode", g) }
        if let d = difficulty, ["peaceful", "easy", "normal", "hard"].contains(d) { _ = props.set("difficulty", d) }
        if let m = motd?.trimmingCharacters(in: .whitespaces), !m.isEmpty, !m.contains("\n") { _ = props.set(bedrock ? "server-name" : "motd", m) }
        if let mp = maxPlayers, (1...1000).contains(mp) { _ = props.set("max-players", String(mp)) }
        try? props.save()
    }

    // MARK: - Change version (port of provision::change_version)

    /// Swap an existing server's jar/loader in place; world, mods, configs
    /// untouched. Vanilla/Paper/Fabric only (Forge/NeoForge need their
    /// installer's multi-file output replaced as a set — same limit as Rust).
    /// Improvement: downloads into a staging folder first and only then
    /// trashes the old launcher, so a failed download leaves the server
    /// runnable (Rust deleted the old jar before downloading).
    static func changeVersion(dir: URL, oldLaunchTarget: String, name: String, ramMB: UInt32, javaPath: String,
                              loader: Loader, mcVersion: String, loaderVersion: String?,
                              progress: @escaping (ProvisionProgress) -> Void) async throws -> Created {
        guard [.vanilla, .paper, .fabric].contains(loader) else {
            throw ProvisionError.message("Changing to Forge or NeoForge isn't supported yet — create a new server for that.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProvisionError.message("Server folder not found.")
        }
        let fm = FileManager.default
        let staging = dir.appending(path: ".craftpanel-staging-\(Int(Date().timeIntervalSince1970))")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) } // only ever holds our fresh download
        let spec = CreateSpec(loader: loader, mcVersion: mcVersion, loaderVersion: loaderVersion, dir: staging,
                              name: name, ramMB: ramMB, javaPath: javaPath)
        let target: String
        switch loader {
        case .vanilla: target = try await downloadVanilla(spec, dir: staging, progress: progress)
        case .paper: target = try await downloadPaper(spec, dir: staging, progress: progress)
        default: target = try await downloadFabric(spec, dir: staging, progress: progress)
        }
        let trash = dir.appending(path: ".craftpanel-trash")
        for old in Set([oldLaunchTarget, target]) {
            let p = dir.appending(path: old)
            if let safe = try? ServerFileCollector.safeFileName(old), safe == old, fm.fileExists(atPath: p.path) {
                try ServerFileCollector.moveToTrash(p, trashDir: trash)
            }
        }
        try fm.moveItem(at: staging.appending(path: target), to: dir.appending(path: target))
        progress(ProvisionProgress(stage: "done", message: "Switched to \(loader.label) \(mcVersion)", pct: 100))
        return Created(serverType: loader.serverType, launchTarget: target, mcVersion: mcVersion, dir: dir, javaPath: javaPath)
    }

    // MARK: - Downloads

    static func downloadTo(_ urlString: String, dest: URL, label: String, progress: (ProvisionProgress) -> Void) async throws {
        progress(ProvisionProgress(stage: "download", message: "Downloading \(label)…", pct: 0))
        guard let url = URL(string: urlString) else { throw ProvisionError.message("bad download URL") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProvisionError.message("download failed: \(error.localizedDescription)")
        }
        // An error page must never be saved as server.jar.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProvisionError.message("download of \(label) failed (HTTP \(http.statusCode))")
        }
        try data.write(to: dest, options: .atomic)
        progress(ProvisionProgress(stage: "download", message: "Downloaded \(label) (\(data.count / 1_048_576) MB)", pct: 100))
    }

    static func sha1Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func downloadVanilla(_ spec: CreateSpec, dir: URL, progress: (ProvisionProgress) -> Void) async throws -> String {
        let manifest = try await getJSON("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
        guard let obj = manifest as? [String: Any], let versions = obj["versions"] as? [[String: Any]],
              let entry = versions.first(where: { ($0["id"] as? String) == spec.mcVersion }),
              let pkgURL = entry["url"] as? String else {
            throw ProvisionError.message("Minecraft \(spec.mcVersion) not found")
        }
        let pkg = try await getJSON(pkgURL)
        guard let pkgObj = pkg as? [String: Any], let downloads = pkgObj["downloads"] as? [String: Any],
              let server = downloads["server"] as? [String: Any], let url = server["url"] as? String else {
            throw ProvisionError.message("this version has no server download")
        }
        let wantSHA1 = server["sha1"] as? String ?? ""

        let dest = dir.appending(path: "server.jar")
        try await downloadTo(url, dest: dest, label: "Minecraft server", progress: progress)
        if !wantSHA1.isEmpty {
            progress(ProvisionProgress(stage: "verify", message: "Verifying checksum", pct: nil))
            let got = try sha1Hex(dest)
            guard got == wantSHA1 else { throw ProvisionError.message("checksum mismatch (sha1 \(got) != \(wantSHA1))") }
        }
        return "server.jar"
    }

    private static func downloadPaper(_ spec: CreateSpec, dir: URL, progress: (ProvisionProgress) -> Void) async throws -> String {
        let builds = try await getJSON("https://fill.papermc.io/v3/projects/paper/versions/\(spec.mcVersion)/builds")
        guard let list = builds as? [[String: Any]], !list.isEmpty else { throw ProvisionError.message("no builds") }
        let build = list.first { ($0["channel"] as? String) == "STABLE" } ?? list.first!
        guard let downloads = build["downloads"] as? [String: Any], let dl = downloads["server:default"] as? [String: Any],
              let url = dl["url"] as? String else {
            throw ProvisionError.message("no download url")
        }
        let name = dl["name"] as? String ?? "paper.jar"
        let want = (dl["checksums"] as? [String: Any])?["sha256"] as? String ?? ""

        let dest = dir.appending(path: name)
        try await downloadTo(url, dest: dest, label: name, progress: progress)
        if !want.isEmpty {
            progress(ProvisionProgress(stage: "verify", message: "Verifying checksum", pct: nil))
            let got = try sha256Hex(dest)
            guard got == want else { throw ProvisionError.message("checksum mismatch (sha256 \(got) != \(want))") }
        }
        return name
    }

    static func downloadFabric(_ spec: CreateSpec, dir: URL, progress: (ProvisionProgress) -> Void) async throws -> String {
        let loaderVersion: String
        if let pinned = spec.loaderVersion {
            loaderVersion = pinned
        } else {
            let v = try await getJSON("https://meta.fabricmc.net/v2/versions/loader")
            guard let arr = v as? [[String: Any]] else { throw ProvisionError.message("no fabric loader") }
            let stable = arr.first { ($0["stable"] as? Bool) == true } ?? arr.first
            guard let ver = stable?["version"] as? String else { throw ProvisionError.message("no fabric loader") }
            loaderVersion = ver
        }
        let iv = try await getJSON("https://meta.fabricmc.net/v2/versions/installer")
        guard let iarr = iv as? [[String: Any]] else { throw ProvisionError.message("no fabric installer") }
        let istable = iarr.first { ($0["stable"] as? Bool) == true } ?? iarr.first
        guard let installer = istable?["version"] as? String else { throw ProvisionError.message("no fabric installer") }

        let url = "https://meta.fabricmc.net/v2/versions/loader/\(spec.mcVersion)/\(loaderVersion)/\(installer)/server/jar"
        let dest = dir.appending(path: "fabric-server-launch.jar")
        try await downloadTo(url, dest: dest, label: "Fabric server launcher", progress: progress)
        return "fabric-server-launch.jar"
    }

    static func runInstaller(_ spec: CreateSpec, dir: URL, java: String, progress: (ProvisionProgress) -> Void) async throws -> String {
        guard let ver = spec.loaderVersion else {
            throw ProvisionError.message("pick a loader version for NeoForge/Forge")
        }
        let url: String, installerName: String, installFlag: String
        if spec.loader == .neoforge {
            url = "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(ver)/neoforge-\(ver)-installer.jar"
            installerName = "neoforge-\(ver)-installer.jar"
            installFlag = "--install-server"
        } else {
            url = "https://maven.minecraftforge.net/net/minecraftforge/forge/\(ver)/forge-\(ver)-installer.jar"
            installerName = "forge-\(ver)-installer.jar"
            installFlag = "--installServer"
        }
        let installerPath = dir.appending(path: installerName)
        try await downloadTo(url, dest: installerPath, label: installerName, progress: progress)

        progress(ProvisionProgress(stage: "install", message: "Running the loader installer (this takes a minute)…", pct: nil))
        let out = try await runProcess(java, args: ["-jar", installerName, installFlag], cwd: dir)
        if !out.success {
            let tail = String(out.stderr.prefix(800))
            throw ProvisionError.message("installer failed:\n\(tail)")
        }
        try? FileManager.default.removeItem(at: installerPath)
        try? FileManager.default.removeItem(at: dir.appending(path: "\(installerName).log"))

        if MinecraftAdapter.forgeArgsFile(dir: dir) != nil || FileManager.default.fileExists(atPath: dir.appending(path: "run.sh").path) {
            return "run.sh" // MinecraftAdapter.startCommand resolves the args file itself
        }
        throw ProvisionError.message("installer finished but produced no run script or args file")
    }

    /// Installers (Forge/NeoForge/Fabric) can run for minutes and print a lot
    /// on both streams; `Subprocess` drains both concurrently off the main
    /// actor. (Old version read stdout to EOF before stderr — a deadlock
    /// once stderr filled — and blocked whichever thread awaited it.)
    private static func runProcess(_ executable: String, args: [String], cwd: URL) async throws -> (success: Bool, stdout: String, stderr: String) {
        let r: Subprocess.Result
        do {
            r = try await Subprocess.runAsync(MinecraftAdapter.resolveExecutable(executable).path, args, cwd: cwd, timeout: 20 * 60)
        } catch {
            throw ProvisionError.message("couldn't run installer: \(error.localizedDescription)")
        }
        if r.timedOut { throw ProvisionError.message("installer took longer than 20 minutes and was stopped") }
        return (r.status == 0, r.stdoutString, r.stderrString)
    }

    // MARK: - First boot

    static func firstBoot(
        _ spec: CreateSpec, dir: URL, java: String, launchTarget: String, serverType: ServerType,
        progress: @escaping (ProvisionProgress) -> Void
    ) async throws {
        progress(ProvisionProgress(stage: "firstboot", message: "Starting the server once to generate its config…", pct: nil))

        let config = ServerConfig(
            path: dir, launchTarget: launchTarget, javaPath: java,
            ramMB: min(spec.ramMB, 2048), // first boot is light
            serverType: serverType, jvmArgs: nil
        )
        MinecraftAdapter.ensureUserJVMArgs(config: config)
        let process = MinecraftAdapter().startCommand(config: config)

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Never-read Pipe used to fill up and stall a chatty JVM's first boot.
        process.standardError = FileHandle.nullDevice
        try process.run()

        ServerSession.write(dir: dir, session: ServerSession(
            pid: process.processIdentifier, launcherPid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Int64(Date().timeIntervalSince1970), rconPort: nil, rconPassword: nil
        ))

        // Watched from the pipe's own readability callback (fires on an
        // arbitrary queue), so the polling loop below can check the
        // deadline every 500ms regardless of whether the server is
        // actually saying anything right now — world-gen can go quiet
        // for a while, and that must never look like a hang. Matches
        // `first_boot`'s own `rx.recv_timeout(500ms)` polling loop
        // exactly, just backed by an actor instead of a channel.
        let watch = BootWatch()
        let lineBuffer = LineBuffer() // keeps partial lines across reads ("Done (" split in two)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in lineBuffer.append(data) {
                Task { await watch.observe(line) }
            }
        }

        var ready = false
        let deadline = Date().addingTimeInterval(firstBootTimeout)
        while Date() < deadline {
            if await watch.ready { ready = true; break }
            if await watch.eulaBlocked { break }
            if !process.isRunning { break } // exited on its own
            try? await Task.sleep(for: .milliseconds(500))
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        var exited = false
        if ready {
            if let data = "stop\n".data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }
            for _ in 0..<180 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            exited = !process.isRunning
        }
        if !exited {
            process.terminate()
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        let level = Properties.load(dir: dir).getOr("level-name", "world")
        try? FileManager.default.removeItem(at: dir.appending(path: level).appending(path: "session.lock"))
        ServerSession.clear(dir: dir)
        try? await Task.sleep(for: .milliseconds(400))

        guard FileManager.default.fileExists(atPath: dir.appending(path: "server.properties").path) else {
            throw ProvisionError.message("first boot didn't generate server.properties — the Java version may be too old for this Minecraft version")
        }
        progress(ProvisionProgress(stage: "done", message: "Server ready", pct: 100))
    }
}
