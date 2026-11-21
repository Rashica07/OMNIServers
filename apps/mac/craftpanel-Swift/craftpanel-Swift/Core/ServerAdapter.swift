import Foundation

/// Game-specific server logic lives behind this protocol — the rest of
/// the app (process management, the UI) only ever talks through it, so
/// adding a second game later (FiveM) doesn't touch anything upstream.
/// Mirrors `adapter::ServerAdapter` in the Rust core.
nonisolated protocol ServerAdapter {
    /// Inspect a folder and report what kind of server (if any) lives
    /// there. A static requirement, not an instance method — detection
    /// doesn't need a live adapter instance, matching the Rust trait's
    /// `fn detect(path: &Path) -> Option<ServerType> where Self: Sized`.
    static func detect(at path: URL) -> ServerType?

    /// Build the process that launches this server. No shell involved —
    /// arguments are passed as an array, never interpolated into a
    /// shell string.
    func startCommand(config: ServerConfig) -> Process

    /// Interpret a chunk of console output into a coarse status.
    func parseStatus(output: String) -> ServerStatus
}

/// Real, typed errors — the one deliberate departure from the Rust core,
/// which uses plain `String` errors throughout as a pragmatic shortcut.
/// Swift's `LocalizedError` gives call sites (SwiftUI alerts, logs) a
/// real error to switch on instead of string-matching.
enum DetectionError: LocalizedError, Sendable {
    case notADirectory(URL)
    case unreadable(URL, underlying: String)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            "That path is not a folder: \(url.path)"
        case .unreadable(let url, let underlying):
            "Couldn't read \(url.path): \(underlying)"
        }
    }
}
