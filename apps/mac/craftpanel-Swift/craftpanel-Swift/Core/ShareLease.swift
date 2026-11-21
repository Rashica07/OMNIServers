import Foundation

/// Multi-device sharing, MVP: a server folder that lives in a synced
/// location (iCloud Drive / Dropbox / SMB) is claimed by exactly one
/// device at a time via an advisory lease file. The sync provider moves
/// the world; the lease stops two devices running it at once and
/// corrupting the save. Direct port of `share.rs`.
///
/// Files written into the server folder:
///   craftpanel-share.json  — { code, name, createdBy }              (static)
///   craftpanel-lease.json  — { holder, hostname, claimedAt, expiresAt } (mutable)
/// **Field names are on-disk format, not just Swift API** — `ShareInfo`/
/// `Lease` have no `rename_all` on the Rust side, so the JSON keys are
/// Rust's raw snake_case field names (`created_by`, `claimed_at`,
/// `expires_at`). Kept exactly via `CodingKeys` so a folder shared
/// between a Tauri-app device and a Swift-app device actually interops —
/// this is the one file in this port where cross-app on-disk
/// compatibility is the whole point, not an implementation detail.
nonisolated struct ShareInfo: Codable, Sendable {
    var code: String
    var name: String
    var createdBy: String

    enum CodingKeys: String, CodingKey {
        case code, name
        case createdBy = "created_by"
    }
}

nonisolated struct Lease: Codable, Sendable {
    /// stable per-device id
    var holder: String
    /// human name of the holding machine
    var hostname: String
    var claimedAt: Int64
    var expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case holder, hostname
        case claimedAt = "claimed_at"
        case expiresAt = "expires_at"
    }
}

nonisolated struct ShareView: Sendable {
    var shared: Bool
    var code: String?
    /// lease held by anyone right now (and not expired)
    var locked: Bool
    /// the current device holds it
    var heldByUs: Bool
    var holderName: String?
    /// seconds until the current lease expires (negative if stale)
    var expiresIn: Int64?
}

nonisolated enum ShareLease {
    static let shareFile = "craftpanel-share.json"
    static let leaseFile = "craftpanel-lease.json"
    /// A running device refreshes its lease well inside this window.
    static let leaseTTLSecs: Int64 = 120

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    /// **Native win**: `Host.current().localizedName` reads the Mac's own
    /// "Computer Name" directly — no `scutil`/`hostname` subprocess
    /// needed the way the Rust side (no std API for this) has to shell out.
    static func hostname() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Generate a share code: 8 chars, no vowels or look-alikes (0/O, 1/I).
    static func genCode() -> String {
        let alphabet = Array("23456789BCDFGHJKMNPQRSTVWXZ")
        var out = ""
        let bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        for (i, byte) in bytes.prefix(8).enumerated() {
            if i == 4 { out.append("-") }
            out.append(alphabet[Int(byte) % alphabet.count])
        }
        return out
    }

    static func readShare(dir: URL) -> ShareInfo? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(shareFile)) else { return nil }
        return try? JSONDecoder().decode(ShareInfo.self, from: data)
    }

    static func readLease(dir: URL) -> Lease? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(leaseFile)) else { return nil }
        return try? JSONDecoder().decode(Lease.self, from: data)
    }

    /// Write the share marker. Errors if the folder is already shared.
    @discardableResult
    static func createShare(dir: URL, name: String) throws -> ShareInfo {
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(shareFile).path) else {
            throw RconServiceError.message("This server is already shared.")
        }
        let info = ShareInfo(code: genCode(), name: name, createdBy: hostname())
        try writeJSON(dir.appendingPathComponent(shareFile), info)
        return info
    }

    static func view(dir: URL, deviceID: String) -> ShareView {
        guard let info = readShare(dir: dir) else {
            return ShareView(shared: false, code: nil, locked: false, heldByUs: false, holderName: nil, expiresIn: nil)
        }
        guard let lease = readLease(dir: dir) else {
            return ShareView(shared: true, code: info.code, locked: false, heldByUs: false, holderName: nil, expiresIn: nil)
        }
        let remaining = lease.expiresAt - now()
        return ShareView(
            shared: true, code: info.code, locked: remaining > 0,
            heldByUs: lease.holder == deviceID, holderName: lease.hostname, expiresIn: remaining
        )
    }

    /// Try to take the lease. `force` overrides a stale-but-present or
    /// (with an explicit user OK) a live lease.
    @discardableResult
    static func claim(dir: URL, deviceID: String, force: Bool) throws -> Lease {
        guard readShare(dir: dir) != nil else {
            // not a shared server — nothing to claim
            return Lease(holder: deviceID, hostname: hostname(), claimedAt: now(), expiresAt: now() + leaseTTLSecs)
        }
        if let existing = readLease(dir: dir) {
            let live = existing.expiresAt > now()
            if existing.holder != deviceID, live, !force {
                let mins = max((existing.expiresAt - now()) / 60, 0)
                throw RconServiceError.message("In use on \"\(existing.hostname)\" — its lease has ~\(mins) min left. Start anyway only if that device is actually off.")
            }
        }
        let lease = Lease(holder: deviceID, hostname: hostname(), claimedAt: now(), expiresAt: now() + leaseTTLSecs)
        try writeJSON(dir.appendingPathComponent(leaseFile), lease)
        return lease
    }

    /// Extend our lease. No-op if we no longer hold it.
    static func heartbeat(dir: URL, deviceID: String) {
        guard readShare(dir: dir) != nil, var lease = readLease(dir: dir), lease.holder == deviceID else { return }
        lease.expiresAt = now() + leaseTTLSecs
        try? writeJSON(dir.appendingPathComponent(leaseFile), lease)
    }

    /// Refuses if another device currently holds a live lease. Matches
    /// `unshare_server`'s own guard exactly.
    static func unshare(dir: URL, deviceID: String) throws {
        let v = view(dir: dir, deviceID: deviceID)
        if v.locked, !v.heldByUs {
            throw RconServiceError.message("It's in use on another device right now — try again when it's free.")
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(leaseFile))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(shareFile))
    }

    static func release(dir: URL, deviceID: String) {
        guard let lease = readLease(dir: dir), lease.holder == deviceID else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(leaseFile))
    }

    private static func writeJSON<T: Encodable>(_ path: URL, _ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        // A sync client must never observe a half-written JSON lease.
        try data.write(to: path, options: .atomic)
    }

    /// This Mac's stable device id, persisted in Application Support —
    /// same location the SwiftData store already lives in.
    static let thisDeviceID: String = deviceID(
        configDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )

    /// Stable per-device id, persisted in the app config dir.
    static func deviceID(configDir: URL) -> String {
        let path = configDir.appendingPathComponent("device-id")
        if let existing = try? String(contentsOf: path, encoding: .utf8) {
            let t = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? id.write(to: path, atomically: true, encoding: .utf8)
        return id
    }
}
