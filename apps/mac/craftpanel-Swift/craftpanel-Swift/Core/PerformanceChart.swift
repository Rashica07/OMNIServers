import Foundation

/// Time windows and number-crunching for the Performance tab's graph (mirrors the Windows app).
nonisolated enum PerformanceChart {
    /// Live ranges come from the 2-second sampler while the tab is open; the longer ones from the stored per-minute history.
    enum Range: String, CaseIterable, Identifiable {
        case m1 = "1m", m5 = "5m", h1 = "1h", h24 = "24h", d7 = "7d"
        var id: String { rawValue }
        var seconds: Int64 {
            switch self { case .m1: 60; case .m5: 300; case .h1: 3600; case .h24: 86_400; case .d7: 604_800 }
        }
        var isLive: Bool { self == .m1 || self == .m5 }
    }

    /// Evenly spaced points for drawing: at most `maxPoints`, averaging neighbours so spikes aren't dropped.
    static func downsample(_ values: [Double], maxPoints: Int) -> [Double] {
        guard values.count > maxPoints, maxPoints >= 2 else { return values }
        return (0..<maxPoints).map { i in
            let from = i * values.count / maxPoints
            let to = max(from + 1, (i + 1) * values.count / maxPoints)
            let slice = values[from..<to]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    static func uptime(since started: Date?, now: Date) -> String {
        guard let started else { return "—" }
        let t = max(0, Int(now.timeIntervalSince(started)))
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m \(String(format: "%02d", t % 60))s" }
        if t < 86_400 { return "\(t / 3600)h \(String(format: "%02d", t % 3600 / 60))m" }
        return "\(t / 86_400)d \(t % 86_400 / 3600)h"
    }
}
