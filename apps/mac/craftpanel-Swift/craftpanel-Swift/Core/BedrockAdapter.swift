import Foundation

/// Mirrors `bedrock::BedrockDetection` — deliberately not a
/// `MinecraftAdapter` case. A Bedrock Dedicated Server is a native OS
/// process, not a JVM: no RCON, no `eula.txt`, no version-history file to
/// pull an MC version out of, so there's just the one field.
struct BedrockDetection: Codable, Sendable {
    var launchTarget: String
}

nonisolated enum BedrockAdapter {
    static var binaryName: String {
        #if os(Windows)
        "bedrock_server.exe"
        #else
        "bedrock_server"
        #endif
    }

    /// `false` on macOS — there is no Bedrock Dedicated Server build for
    /// it, and there never has been (Mojang ships Windows + Linux only).
    /// Callers should check this *before* offering Bedrock as a create
    /// option at all, not just at download time.
    static var isPlatformSupported: Bool {
        #if os(Windows) || os(Linux)
        true
        #else
        false
        #endif
    }

    static func inspect(at path: URL) -> BedrockDetection? {
        let target = binaryName
        var isDir: ObjCBool = false
        let candidate = path.appending(path: target)
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return BedrockDetection(launchTarget: target)
    }

    static func parseStatus(_ text: String) -> ServerStatus {
        let o = text.lowercased()
        if o.contains("server started.") { return .running }
        if o.contains("stopping server") { return .stopping }
        return .unknown
    }
}
