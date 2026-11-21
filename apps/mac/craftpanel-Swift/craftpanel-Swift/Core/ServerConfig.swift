import Foundation

/// Everything an adapter needs to build a launch command.
struct ServerConfig: Codable, Sendable {
    /// Absolute path to the server directory.
    var path: URL
    /// The launch jar (or run script), relative to `path`.
    var launchTarget: String
    /// `java` executable to use (absolute path, or bare `java` to
    /// resolve off PATH).
    var javaPath: String
    /// Heap size in megabytes. `-Xms` and `-Xmx` are always set equal.
    var ramMB: UInt32
    var serverType: ServerType
    /// Extra JVM flags (Aikar's / GC tuning) — whitespace-split, only
    /// tokens starting with `-` are kept. `nil`/empty is the common case.
    var jvmArgs: String?
}

/// Coarse run-state parsed from console output.
enum ServerStatus: String, Codable, Sendable {
    case starting, running, stopping, stopped, crashed, unknown
}
