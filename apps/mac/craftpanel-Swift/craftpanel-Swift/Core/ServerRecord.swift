import Foundation
import SwiftData

/// A saved server, persisted locally via SwiftData. The Swift-native
/// equivalent of `db.rs`'s `servers` SQLite table — same fields, same
/// role (what OMNIServers remembers about a server between launches),
/// just backed by SwiftData's on-disk store instead of hand-rolled SQL.
@Model
final class ServerRecord {
    var id: UUID = UUID()
    var name: String = ""
    /// Absolute path to the server's folder on disk.
    var path: String = ""
    /// Stored as the enum's raw value — SwiftData doesn't need a
    /// converter for that the way a hand-rolled SQL column would.
    var serverTypeRaw: String = ServerType.vanilla.rawValue
    var launchTarget: String = ""
    var mcVersion: String?
    /// Absolute path, or bare `java` to resolve off PATH.
    var javaPath: String = "java"
    var ramMB: UInt32 = 4096
    var createdAt: Date = Date.now
    /// Per-server automation config (crash-restart, daily restart, timed
    /// commands, backup/snapshot triggers), serialized JSON — the
    /// SwiftData equivalent of the Rust side's `settings` table row keyed
    /// `schedule.<id>`. Optional, so existing servers migrate for free
    /// with no schedule set (same as an absent DB row). See
    /// `Schedule`/`ScheduleStore`.
    var scheduleJSON: String?
    /// A saved permanent join address (playit.gg/ngrok/etc.) — the
    /// SwiftData equivalent of the Rust side's `settings` table row keyed
    /// `tunnel.<id>`. Wins over the LAN address but loses to a live
    /// in-app tunnel; see `NetworkView`'s "recommended address" logic.
    var manualTunnelAddress: String?
    /// Extra JVM flags (Aikar's / GC tuning), whitespace-split at launch
    /// time. Mirrors the Rust side's `jvm_args` column.
    var jvmArgs: String?

    var serverType: ServerType {
        get { ServerType(rawValue: serverTypeRaw) ?? .vanilla }
        set { serverTypeRaw = newValue.rawValue }
    }

    init(
        name: String,
        path: String,
        serverType: ServerType,
        launchTarget: String,
        mcVersion: String?,
        javaPath: String,
        ramMB: UInt32
    ) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.serverTypeRaw = serverType.rawValue
        self.launchTarget = launchTarget
        self.mcVersion = mcVersion
        self.javaPath = javaPath
        self.ramMB = ramMB
        self.createdAt = .now
    }
}
