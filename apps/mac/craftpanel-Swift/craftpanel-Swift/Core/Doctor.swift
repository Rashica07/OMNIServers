import Foundation
import Darwin

/// A pre-flight health check: Java, disk space, and port availability —
/// everything that would otherwise surface as a confusing error the
/// moment someone tries to create or start a server. One button in
/// OMNIServers Settings, run all checks, tell the admin what's wrong
/// *before* it becomes a failure instead of explaining it after.
///
/// Direct port of `doctor.rs`, minus the R2 cloud-sync check — cloud
/// sync itself isn't wired into this build (see the memory note on why),
/// so there's nothing for a "cloud sync" check to report on yet.
nonisolated struct DoctorCheck: Sendable, Identifiable {
    var id: String
    var label: String
    var ok: Bool
    var detail: String
}

nonisolated struct DoctorReport: Sendable {
    var checks: [DoctorCheck]
    var allOK: Bool
}

nonisolated enum Doctor {
    private static let minFreeGB: UInt64 = 2

    private static func checkJava() async -> DoctorCheck {
        if let j = await JavaProbe.probe() {
            return DoctorCheck(id: "java", label: "Java", ok: true, detail: "Java \(j.major) found at \(j.path)")
        }
        return DoctorCheck(id: "java", label: "Java", ok: false,
                            detail: "No Java runtime found on PATH. Servers won't be able to start until one's installed.")
    }

    /// Free space on whichever volume the app's data directory lives on.
    private static func checkDisk(appDataDir: URL) -> DoctorCheck {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? appDataDir.resourceValues(forKeys: keys),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return DoctorCheck(id: "disk", label: "Disk space", ok: true, detail: "Couldn't check — not a blocker.")
        }
        let freeGB = UInt64(max(0, bytes)) / 1_073_741_824
        return DoctorCheck(
            id: "disk", label: "Disk space", ok: freeGB >= minFreeGB,
            detail: freeGB >= minFreeGB
                ? "\(freeGB) GB free"
                : "Only \(freeGB) GB free — worlds and backups fill up fast, free some space before creating a new server."
        )
    }

    /// Binds a TCP socket to `port` on all interfaces to test availability
    /// — the actual free/taken answer, not just "not in our own server
    /// list," matching `external::port_free`'s own real-bind check.
    static func portFree(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    private static func checkPort(taken: Set<UInt16>) -> DoctorCheck {
        for p in UInt16(25565)..<25665 where !taken.contains(p) && portFree(p) {
            return DoctorCheck(id: "port", label: "Network port", ok: true, detail: "Port \(p) is free for a new server.")
        }
        return DoctorCheck(id: "port", label: "Network port", ok: false,
                            detail: "Every port from 25565–25665 is already in use — something's unusual here.")
    }

    static func run(servers: [ServerRecord], appDataDir: URL) async -> DoctorReport {
        let taken = Set(servers.map { NetworkInfo.port(serverDir: URL(fileURLWithPath: $0.path)) })
        let checks = [await checkJava(), checkDisk(appDataDir: appDataDir), checkPort(taken: taken)]
        return DoctorReport(checks: checks, allOK: checks.allSatisfy(\.ok))
    }
}

/// Builds a shareable support bundle without collecting server files or secrets.
/// Only system facts, health-check results, and the selected server's recent log
/// are included; usernames, computer names, local IPs, and credential-like log
/// values are removed before anything is written.
nonisolated enum ProblemReport {
    static func build(description: String, servers: [ServerRecord], selectedServerID: UUID?, appDataDir: URL) async throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "craftpanel-report-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let memory = await SystemMemory.detailed()
        let doctor = await Doctor.run(servers: servers, appDataDir: appDataDir)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var lines = [
            "OMNIServers support report",
            "Created: \(ISO8601DateFormatter().string(from: Date()))",
            "App version: \(appVersion)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(architecture)",
            "Memory: \(SystemRAM.format(mb: memory.totalMB)) \(memory.memoryType ?? "")",
            "Chip: \(memory.chip)",
            "Cores: \(memory.cores)",
            "Available memory: \(SystemRAM.format(mb: memory.availableMB))",
            "Servers in OMNIServers: \(servers.count)",
            "",
            "Health check:",
        ]
        lines += doctor.checks.map { "- \($0.label): \($0.ok ? "OK" : "Needs attention") — \($0.detail)" }
        lines += ["", "Servers:"]
        lines += servers.map { "- \($0.name) (\($0.serverType.label)\($0.mcVersion.map { " \($0)" } ?? ""))" }
        lines += ["", "User description:", description.isEmpty ? "(not provided)" : description]
        try redact(lines.joined(separator: "\n")).write(to: staging.appending(path: "report.txt"), atomically: true, encoding: .utf8)

        if let selectedServerID, let selected = servers.first(where: { $0.id == selectedServerID }) {
            let root = URL(fileURLWithPath: selected.path)
            let log = root.appending(path: "logs/latest.log")
            if let text = try? String(contentsOf: log, encoding: .utf8) {
                let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(500).joined(separator: "\n")
                try redact(tail).write(to: staging.appending(path: "server-log.txt"), atomically: true, encoding: .utf8)
            }
            if let crash = CrashReports.latest(serverDir: root) {
                let crashURL = root.appending(path: "crash-reports/\(crash.file)")
                if let text = try? String(contentsOf: crashURL, encoding: .utf8) {
                    try redact(text).write(to: staging.appending(path: "server-crash.txt"), atomically: true, encoding: .utf8)
                }
            }
        }

        let zip = fm.temporaryDirectory.appending(path: "CraftPanel-report-\(Int(Date().timeIntervalSince1970)).zip")
        try? fm.removeItem(at: zip)
        let result = try Subprocess.run("/usr/bin/zip", ["-q", "-r", zip.path, "."], cwd: staging, timeout: 30)
        guard result.status == 0 else {
            try? fm.removeItem(at: zip)
            throw RconServiceError.message("Could not create the report archive: \(result.stderrString)")
        }
        return zip
    }

    static func redact(_ input: String, username: String = NSUserName(), hostname: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName, lanIP: String? = NetworkInfo.lanIP()) -> String {
        var result = input
        for (value, replacement) in [(username, "<user>"), (hostname, "<computer>"), (lanIP ?? "", "<local-ip>")] where !value.isEmpty {
            result = result.replacingOccurrences(of: value, with: replacement, options: [.caseInsensitive])
        }
        result = result.replacingOccurrences(of: "/Users/[^/\\s]+", with: "~/…", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?im)^.*(?:password|token|secret|api[_-]?key)\\s*[:=].*$", with: "<credential-like log line removed>", options: .regularExpression)
        return result
    }

    private static var architecture: String {
        #if arch(arm64)
        "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        "Intel (x86_64)"
        #else
        "Unknown"
        #endif
    }
}
