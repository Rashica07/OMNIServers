import Foundation

/// The orchestrating entry point the Add Server flow actually calls —
/// mirrors `commands::detect_server` exactly: try Minecraft first (its
/// own precedence handles Fabric/Forge/Paper/Spigot/Vanilla), fall back
/// to Bedrock, and if neither matches, return a clear, actionable
/// "nothing here" result rather than throwing. Detection failing isn't
/// exceptional — an empty or unrelated folder is an expected input from
/// a folder picker, so this returns a result type, not `throws`.
struct DetectionResult: Sendable {
    var path: URL
    var detected: Bool
    var serverType: ServerType?
    var launchTarget: String?
    var mcVersion: String?
    var evidence: [String]
    var java: JavaInfo?
    var warnings: [String]
}

enum ServerDetector {
    /// `async` — probes `java -version` as part of a full detection pass,
    /// same as `detect_server` does synchronously on the Rust side (Tauri
    /// commands already run off the main thread there; here that's what
    /// `async` buys explicitly).
    static func detect(at path: URL, javaExecutable: String? = nil) async -> DetectionResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue else {
            return DetectionResult(
                path: path, detected: false, serverType: nil, launchTarget: nil,
                mcVersion: nil, evidence: [], java: nil, warnings: ["That path is not a folder."]
            )
        }

        var warnings: [String] = []
        let java = await JavaProbe.probe(exe: javaExecutable)

        if let d = MinecraftAdapter.inspect(at: path) {
            if java == nil {
                warnings.append("No Java runtime found on PATH. Install a JDK (Temurin 17, 21, or 25) before starting this server.")
            }
            if let j = java, let w = JavaProbe.compatibilityWarning(java: j, mcVersion: d.mcVersion) {
                warnings.append(w)
            }
            if d.mcVersion == nil {
                warnings.append("Couldn't determine the Minecraft version automatically — set it manually if Java looks mismatched.")
            }
            return DetectionResult(
                path: path, detected: true, serverType: d.serverType,
                launchTarget: d.launchTarget, mcVersion: d.mcVersion,
                evidence: d.evidence, java: java, warnings: warnings
            )
        }

        if let d = OmniHostAdapter.inspect(at: path) {
            // OMNIHost is a native Rust engine — needs no Java at all.
            return DetectionResult(
                path: path, detected: true, serverType: .omnihost,
                launchTarget: d.launchTarget, mcVersion: PumpkinEngine.minecraftVersion,
                evidence: [PumpkinConfig.fileName], java: nil, warnings: []
            )
        }

        if let d = BedrockAdapter.inspect(at: path) {
            // A Bedrock server needs no `java` at all — don't warn about
            // it missing just because this folder happens to be Bedrock.
            return DetectionResult(
                path: path, detected: true, serverType: .bedrock,
                launchTarget: d.launchTarget, mcVersion: nil,
                evidence: [d.launchTarget], java: nil, warnings: []
            )
        }

        if let g = GameServers.inspect(at: path) {
            var w = ["OMNIServers will repair the setup (config file, ports) when you add it."]
            if !GameServers.isPlatformSupported(g.type) { w.insert("\(g.type.label) has no server for macOS, so it can be added but not started on this Mac.", at: 0) }
            return DetectionResult(
                path: path, detected: true, serverType: g.type, launchTarget: g.launchTarget,
                mcVersion: nil, evidence: [g.evidence], java: nil, warnings: w
            )
        }

        warnings.append(
            "No Minecraft, FiveM or Terraria server detected here. Expected something like " +
            "fabric-server-launch.jar, a Forge run script, paper.jar, spigot.jar, " +
            "server.jar, or bedrock_server."
        )
        return DetectionResult(
            path: path, detected: false, serverType: nil, launchTarget: nil,
            mcVersion: nil, evidence: [], java: java, warnings: warnings
        )
    }
}
