import Foundation
import UserNotifications

/// Performance alerts — port of `alerts.rs`. Piggybacks on the
/// once-a-minute metrics sample; fires when TPS < 15, RAM > 90% of the
/// allocation, or < 2 GB free disk, with a 15-minute cooldown per
/// (server, kind). Delivered as a macOS notification (so it reaches you
/// with the window closed — the Tauri version only toasted in-app) and a
/// line in that server's console.
nonisolated struct AlertCooldown: Sendable {
    static let tpsWarn: Double = 15
    static let ramWarnFraction: Double = 0.9
    static let diskWarnGB: Int64 = 2
    static let cooldownSecs: Int64 = 15 * 60

    private var lastFired: [String: Int64] = [:]

    mutating func shouldFire(server: UUID, kind: String, now: Int64) -> Bool {
        let key = "\(server)|\(kind)"
        if let last = lastFired[key], now - last < Self.cooldownSecs { return false }
        lastFired[key] = now
        return true
    }

    /// Pure evaluation — which alerts a sample triggers (before cooldown).
    static func evaluate(name: String, allocMB: UInt32, ramMB: UInt32?, tps: Double?, freeDiskGB: Int64?) -> [(kind: String, message: String)] {
        var out: [(String, String)] = []
        if let t = tps, t < tpsWarn { out.append(("lowTps", "\(name) — TPS dropped to \(String(format: "%.1f", t))")) }
        if let mb = ramMB, allocMB > 0 {
            let frac = Double(mb) / Double(allocMB)
            if frac > ramWarnFraction { out.append(("highRam", "\(name) — using \(Int(frac * 100))% of its \(allocMB) MB allocation")) }
        }
        if let gb = freeDiskGB, gb < diskWarnGB { out.append(("lowDisk", "\(name) — only \(gb) GB free on disk")) }
        return out
    }
}

@MainActor
final class PerformanceAlerts {
    static let shared = PerformanceAlerts()
    private var cooldown = AlertCooldown()
    private var askedPermission = false

    func check(record: ServerRecord, runtime: ServerRuntime, ramMB: UInt32?, tps: Double?) {
        let free = (try? URL(fileURLWithPath: record.path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { $0 / 1_073_741_824 }
        let now = Int64(Date().timeIntervalSince1970)
        for a in AlertCooldown.evaluate(name: record.name, allocMB: record.ramMB, ramMB: ramMB, tps: tps, freeDiskGB: free)
        where cooldown.shouldFire(server: record.id, kind: a.kind, now: now) {
            runtime.push(.system, "[alert] \(a.message)")
            notify(a.message)
        }
    }

    private func notify(_ message: String) {
        let center = UNUserNotificationCenter.current()
        if !askedPermission {
            askedPermission = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = "OMNIServers"
        content.body = message
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
