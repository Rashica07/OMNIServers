import Foundation

/// Every server OMNIServers creates or adopts gets one marker file,
/// `.craftpanel-meta.json`, written into its folder. Direct port of
/// `attribution.rs`: a random per-install id (generated once, persisted
/// locally) plus when and how the server was registered — nothing that
/// identifies *you*, just this *install* of the app, so a server can be
/// traced back to the OMNIServers that made it.
///
/// A plain dotfile, not hidden or encrypted by any special trick — same
/// as `.git` or `.craftpanel-trash/` elsewhere in this codebase.
nonisolated enum Attribution {
    private static let metaFileName = ".craftpanel-meta.json"
    private static let installIDKey = "cp.installID"

    private struct Meta: Encodable {
        var craftpanelInstallID: String
        var craftpanelVersion: String
        var createdAt: Int64
        /// "added" (an existing folder someone pointed OMNIServers at) or
        /// "cloned" (Duplicate Server) — the two flows this build
        /// actually has. Rust's own "created" origin (the from-scratch
        /// wizard) has no Swift counterpart yet — that's `provision.rs`,
        /// not built here.
        var origin: String
        private enum CodingKeys: String, CodingKey {
            case craftpanelInstallID = "craftpanelInstallId", craftpanelVersion, createdAt, origin
        }
    }

    /// This install's id — generated once, ever, on first use. Stored in
    /// `UserDefaults`, same as every other app-level setting here (see
    /// `AppDefaults`); the Rust side keeps its equivalent in its own
    /// settings table for the same "one row per app-level setting" reason.
    static var installID: String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: installIDKey)
        return id
    }

    /// Best-effort: a server is still perfectly usable if this write
    /// fails (a read-only folder, a full disk), so callers ignore the
    /// outcome — same contract as the Rust side.
    static func stamp(serverDir: URL, origin: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let meta = Meta(
            craftpanelInstallID: installID, craftpanelVersion: version,
            createdAt: Int64(Date().timeIntervalSince1970), origin: origin
        )
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: serverDir.appending(path: metaFileName))
    }
}
