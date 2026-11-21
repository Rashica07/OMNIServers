import Foundation
import CryptoKit

/// In-app tunnel — no browser, no account. Bundles the `bore` client
/// (github.com/ekzhang/bore): one click gives `bore.pub:<port>` that
/// works from anywhere. Direct port of `tunnel.rs`'s `TunnelManager`.
///
/// The address is stable while the tunnel runs; it changes if the
/// tunnel is restarted. For a permanent custom address the user can
/// still paste a playit.gg/ngrok address in the Network tab instead.
nonisolated struct TunnelStatus: Sendable, Equatable {
    var running = false
    var address: String?
    var error: String?
}

@MainActor
@Observable
final class TunnelManager {
    static let shared = TunnelManager()

    private static let boreVersion = "v0.6.0"
    private(set) var statuses: [UUID: TunnelStatus] = [:]

    private var processes: [UUID: Process] = [:]
    private var readerTasks: [UUID: [Task<Void, Never>]] = [:]

    private init() {}

    func status(_ id: UUID) -> TunnelStatus { statuses[id] ?? TunnelStatus() }

    private var binDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CraftPanel/bore", isDirectory: true)
    }
    private var borePath: URL { binDir.appendingPathComponent("bore") }

    /// (github release asset suffix). Mac-only targets — matches the two
    /// architectures `craftpanel-Swift` actually ships on.
    /// SHA-256 of the official v0.6.0 release archives (pinned 2026-09-28).
    /// A download that doesn't match is refused instead of executed.
    private static let boreSHA256: [String: String] = [
        "aarch64-apple-darwin.tar.gz": "65f43a67b90874700538bdb6064c5e92276e64dfba24f5cd72ef24a035eec3bc",
        "x86_64-apple-darwin.tar.gz": "206db723a382bbc18d2893fc8472868e0b5f41de35975269aab7891ecc8659cc",
    ]

    private func assetSuffix() -> String? {
        #if arch(arm64)
        return "aarch64-apple-darwin.tar.gz"
        #elseif arch(x86_64)
        return "x86_64-apple-darwin.tar.gz"
        #else
        return nil
        #endif
    }

    /// Download + cache the bore client if we don't have it yet. `tar` is
    /// shelled out to for the `.tar.gz` extraction — same "no vendored
    /// codec, `/usr/bin/*` already on every Mac" reasoning as
    /// `AntiCheat`'s `gunzip` call.
    private func ensureBore() async throws -> URL {
        if FileManager.default.fileExists(atPath: borePath.path) { return borePath }
        guard let suffix = assetSuffix() else {
            throw RconServiceError.message("No tunnel client for this Mac's architecture.")
        }
        guard let url = URL(string: "https://github.com/ekzhang/bore/releases/download/\(Self.boreVersion)/bore-\(Self.boreVersion)-\(suffix)") else {
            throw RconServiceError.message("Bad download URL.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (tmp, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RconServiceError.message("Download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let archive = binDir.appendingPathComponent("bore.tar.gz")
        if FileManager.default.fileExists(atPath: archive.path) { try? FileManager.default.removeItem(at: archive) }
        try FileManager.default.moveItem(at: tmp, to: archive)

        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.boreSHA256[suffix] else {
            try? FileManager.default.removeItem(at: archive)
            throw RconServiceError.message("Tunnel client download failed its integrity check — not running it.")
        }
        _ = try await Subprocess.runAsync("/usr/bin/tar", ["-xzf", archive.path, "-C", binDir.path, "bore"], timeout: 60)
        try? FileManager.default.removeItem(at: archive)

        guard FileManager.default.fileExists(atPath: borePath.path) else {
            throw RconServiceError.message("Tunnel client archive didn't contain the binary.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: borePath.path)
        return borePath
    }

    func start(serverID: UUID, port: UInt16) async {
        guard processes[serverID] == nil else { return }
        do {
            let bore = try await ensureBore()
            let proc = Process()
            proc.executableURL = bore
            proc.arguments = ["local", String(port), "--to", "bore.pub"]
            let stdout = Pipe(), stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            try proc.run()
            processes[serverID] = proc
            statuses[serverID] = TunnelStatus(running: true)

            readerTasks[serverID] = [
                Task { [weak self] in await self?.readLines(from: stdout, serverID: serverID) },
                Task { [weak self] in await self?.readLines(from: stderr, serverID: serverID) },
                Task { [weak self] in await self?.watchExit(proc, serverID: serverID) },
            ]
        } catch {
            statuses[serverID] = TunnelStatus(running: false, error: error.localizedDescription)
        }
    }

    /// Called on app quit — bore children otherwise outlive OMNIServers.
    func stopAll() {
        for (_, p) in processes { p.terminate() }
        processes.removeAll()
    }

    func stop(serverID: UUID) {
        processes[serverID]?.terminate()
        processes[serverID] = nil
        readerTasks[serverID]?.forEach { $0.cancel() }
        readerTasks[serverID] = nil
        statuses[serverID] = TunnelStatus()
    }

    private func watchExit(_ proc: Process, serverID: UUID) async {
        while proc.isRunning {
            try? await Task.sleep(for: .milliseconds(600))
        }
        guard !Task.isCancelled, processes[serverID] === proc else { return }
        processes[serverID] = nil
        readerTasks[serverID]?.forEach { $0.cancel() }
        readerTasks[serverID] = nil
        var st = statuses[serverID] ?? TunnelStatus()
        st.running = false
        statuses[serverID] = st
    }

    /// bore logs to stderr; parses "listening at bore.pub:NNNNN" off
    /// whichever pipe carries it, same as the Rust side reading both
    /// stdout and stderr with one parser.
    private func readLines(from pipe: Pipe, serverID: UUID) async {
        for await line in Self.lineStream(from: pipe) {
            let clean = Self.stripANSI(line)
            var st = statuses[serverID] ?? TunnelStatus(running: true)
            if let range = clean.range(of: "listening at ") {
                let addr = clean[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if !addr.isEmpty { st.address = addr }
            }
            let lower = clean.lowercased()
            if lower.contains("error") || lower.contains("failed") || lower.contains("refused") {
                st.error = clean
            }
            statuses[serverID] = st
        }
    }

    /// Drop ANSI colour escapes — bore adds them when stderr looks like a TTY.
    nonisolated static func stripANSI(_ s: String) -> String {
        var out = ""
        var chars = s.makeIterator()
        while let c = chars.next() {
            if c == "\u{1b}" {
                while let d = chars.next(), !d.isLetter {}
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Shared, lock-protected, 64 KB-bounded splitter (was an unsynchronized
    /// captured `pending` buffer that could grow forever without a newline).
    private nonisolated static func lineStream(from pipe: Pipe) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let tail = buffer.flush() { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) { continuation.yield(line) }
            }
            continuation.onTermination = { _ in pipe.fileHandleForReading.readabilityHandler = nil }
        }
    }
}
