import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// A local PIN lock on the app window itself — not network auth, not
/// encryption of the servers on disk, just "don't let someone who picks
/// up this computer poke around your servers without a PIN." Direct port
/// of `lock.rs`'s `Lock`.
///
/// Stored in its own small file (`lock.json`, next to the SwiftData
/// store in Application Support) rather than mixed into the servers
/// database, specifically so "I forgot my PIN" has an honest, low-cost
/// recovery path: delete this one file by hand, not the whole app's data.
///
/// **One deliberate deviation from the Rust source**: this hashes with
/// salted SHA-256 (`CryptoKit`) rather than Argon2 — Argon2 isn't in
/// CryptoKit and this app avoids vendoring a KDF crate for one file.
/// Still a real random-salt-per-PIN hash, not a bare/reused digest (same
/// property the Rust side's own test suite checks for) — just a lighter
/// KDF than Argon2 for a threat model that's explicitly "someone with
/// your laptop open," not an offline cracking adversary. Revisit if that
/// threat model ever changes.
///
/// **Native win**: `BiometricUnlock` (below) offers Touch ID as the
/// primary unlock path via `LocalAuthentication` — the PIN above is the
/// fallback/setup credential, same shape as every other macOS app that
/// offers "unlock with Touch ID or password."
nonisolated struct AppLock {
    /// `phc` (Argon2id, the Rust app's KDF) is the current format; the
    /// legacy salted-SHA-256 fields are still read and upgraded on the next
    /// successful unlock.
    private struct LockFile: Codable {
        var phc: String?
        var saltHex: String?
        var hashHex: String?
    }

    private static let minLen = 4
    private let path: URL

    init(configDir: URL) {
        path = configDir.appendingPathComponent("lock.json")
    }

    /// The real app-data location — Application Support, where the
    /// SwiftData store already lives.
    /// `~/Library/Application Support/CraftPanel/lock.json`. Earlier builds
    /// wrote `lock.json` straight into the shared Application Support root;
    /// that file is moved here on first use.
    static let shared: AppLock = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appending(path: "CraftPanel", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = support.appending(path: "lock.json")
        let current = dir.appending(path: "lock.json")
        if FileManager.default.fileExists(atPath: legacy.path), !FileManager.default.fileExists(atPath: current.path) {
            try? FileManager.default.moveItem(at: legacy, to: current)
        }
        return AppLock(configDir: dir)
    }()

    var isSet: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// Set (or replace) the PIN. No "confirm old PIN" here — the caller
    /// (the Settings UI) only ever offers this once you're already past
    /// the lock screen, same as changing any other setting.
    func set(pin: String) throws {
        let trimmed = pin.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= Self.minLen else {
            throw RconServiceError.message("Use at least \(Self.minLen) characters.")
        }
        // Argon2id with the Rust app's parameters — a 4-digit PIN under a
        // single SHA-256 was brute-forceable in milliseconds.
        let file = LockFile(phc: Argon2.encode(password: trimmed))
        let data = try JSONEncoder().encode(file)
        try data.write(to: path, options: .atomic)
    }

    func check(pin: String) -> Bool {
        guard let data = try? Data(contentsOf: path),
              let file = try? JSONDecoder().decode(LockFile.self, from: data) else { return false }
        if let phc = file.phc { return Argon2.verify(password: pin, phc: phc) }
        guard let saltHex = file.saltHex, let hashHex = file.hashHex, let salt = Self.dataFromHex(saltHex) else { return false }
        let got = Self.hash(pin: pin, salt: salt).map { String(format: "%02x", $0) }.joined()
        guard got.utf8.count == hashHex.utf8.count,
              zip(got.utf8, hashHex.utf8).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return false }
        try? set(pin: pin) // upgrade legacy file to Argon2id
        return true
    }

    /// Requires the current PIN — this removes the lock entirely, so it's
    /// not something a forgotten-PIN dialog should be able to trigger.
    func clear(currentPin: String) throws {
        guard check(pin: currentPin) else {
            throw RconServiceError.message("That PIN isn't right.")
        }
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private static func hash(pin: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(pin.utf8))
        return Data(hasher.finalize())
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        return data
    }
}

/// Touch ID unlock, entirely separate from `AppLock`'s PIN storage/tests
/// — this only ever runs from an explicit user tap on "Unlock with Touch
/// ID," never automatically and never from a test, since biometric
/// evaluation can legitimately block on OS/user interaction.
@MainActor
enum BiometricUnlock {
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}
