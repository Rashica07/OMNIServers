import Foundation

/// App-level preferences that persist across launches -- currently just
/// the defaults a new server is seeded with. Small on purpose: this is
/// the Swift counterpart of the "Defaults for new servers" card in the
/// Tauri app's `SettingsPage.tsx`, not the whole settings page (Java
/// runtime management, diagnostics, remote access, and app lock all
/// still need their own Core layers before this page can honestly claim
/// to cover them -- see AppSettingsView's "coming soon" section for the
/// honest list rather than stub buttons that do nothing). Cloud sync and
/// Discord notifications were scratched outright, not deferred -- see
/// `CurseForgeClient`'s doc comment for the broader reasoning: this app
/// is meant for people who've never heard of an API key or a webhook, so
/// nothing here should ever ask someone to go get one.
nonisolated enum AppDefaults {
    private static let ramKey = "cp.defaultRamMB"
    private static let javaKey = "cp.defaultJavaPath"
    private static let stayAwakeKey = "cp.stayAwakeOnPower"
    private static let lightModeKey = "cp.lightMode"
    private static let helpTourSeenKey = "cp.helpTourSeen"

    static var autoCheckUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "cp.autoCheckUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cp.autoCheckUpdates") }
    }

    static var helpTourSeen: Bool {
        get { UserDefaults.standard.bool(forKey: helpTourSeenKey) }
        set { UserDefaults.standard.set(newValue, forKey: helpTourSeenKey) }
    }

    static var defaultRAMMB: UInt32 {
        get {
            let stored = UserDefaults.standard.integer(forKey: ramKey)
            return stored > 0 ? UInt32(stored) : 4096
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: ramKey) }
    }

    static var defaultJavaPath: String {
        get { UserDefaults.standard.string(forKey: javaKey) ?? "java" }
        set { UserDefaults.standard.set(newValue, forKey: javaKey) }
    }

    /// Stops this Mac from sleeping while it's plugged in — what lets a
    /// per-server scheduled start actually fire. Applied at launch and on
    /// every change; see `PowerKeeper`.
    /// Join/leave/advancement notices (macOS notification in the
    /// background, toast in the app). On by default.
    static var notifyJoins: Bool {
        get { UserDefaults.standard.object(forKey: "cp.notifyJoins") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cp.notifyJoins") }
    }

    /// Every chat message as a notice too. Off by default — busy servers.
    static var notifyChat: Bool {
        get { UserDefaults.standard.bool(forKey: "cp.notifyChat") }
        set { UserDefaults.standard.set(newValue, forKey: "cp.notifyChat") }
    }

    /// The name your messages show under in-game ("<Host> hi").
    static var chatName: String {
        get {
            let n = UserDefaults.standard.string(forKey: "cp.chatName")?.trimmingCharacters(in: .whitespaces) ?? ""
            return n.isEmpty ? "Host" : n
        }
        set { UserDefaults.standard.set(newValue, forKey: "cp.chatName") }
    }

    /// Opens the free tunnel by itself whenever a Java server starts, so friends get an address that works from anywhere. On unless switched off.
    static var autoTunnel: Bool {
        get { UserDefaults.standard.object(forKey: "cp.autoTunnel") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cp.autoTunnel") }
    }

    /// Quit leaves servers running (re-adopted next launch). Tauri: keepServersOnQuit.
    static var keepServersOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: "cp.keepServersOnQuit") }
        set { UserDefaults.standard.set(newValue, forKey: "cp.keepServersOnQuit") }
    }

    /// Shows the raw server.properties editor and other power tools.
    static var expertMode: Bool {
        get { UserDefaults.standard.bool(forKey: "cp.expertMode") }
        set { UserDefaults.standard.set(newValue, forKey: "cp.expertMode") }
    }

    /// Zip backups kept per server (0 = unlimited). Default 20.
    static var backupKeep: Int {
        get { UserDefaults.standard.object(forKey: "cp.backupKeep") as? Int ?? 20 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: "cp.backupKeep") }
    }

    /// Smart retention for zip backups; nil = plain keep-newest-N.
    static var backupTiered: Retention.Tiered? {
        get { UserDefaults.standard.data(forKey: "cp.backupTiered").flatMap { try? JSONDecoder().decode(Retention.Tiered.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "cp.backupTiered") }
    }

    static var stayAwakeOnPower: Bool {
        get { UserDefaults.standard.bool(forKey: stayAwakeKey) }
        set { UserDefaults.standard.set(newValue, forKey: stayAwakeKey) }
    }

    /// Defaults on automatically when the Mac is below the RAM/core guideline.
    static var lightMode: Bool {
        get {
            guard UserDefaults.standard.object(forKey: lightModeKey) != nil else { return SystemMemory.current().isWeak }
            return UserDefaults.standard.bool(forKey: lightModeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: lightModeKey) }
    }

}
