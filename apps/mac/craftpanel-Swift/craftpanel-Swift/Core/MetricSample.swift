import Foundation
import SwiftData

/// One minute-resolution RAM/CPU/TPS sample for one server — the
/// SwiftData equivalent of the Rust side's `metric_samples` SQLite
/// table. Backs the "usage over the last 24h/7d/30d" chart; `perf.rs`'s
/// live numbers (this app's `PerfSampler`) already cover right-now.
@Model
final class MetricSample {
    var serverID: UUID = UUID()
    var ts: Int64 = 0
    var ramMB: Int?
    var cpuPct: Double?
    var tps: Double?

    init(serverID: UUID, ts: Int64, ramMB: Int?, cpuPct: Double?, tps: Double?) {
        self.serverID = serverID
        self.ts = ts
        self.ramMB = ramMB
        self.cpuPct = cpuPct
        self.tps = tps
    }
}

/// One point read back for the chart — a plain, non-model value so views
/// don't hold onto `MetricSample` (and therefore the model context)
/// longer than the query that produced it.
nonisolated struct MetricPoint: Sendable {
    var ts: Int64
    var ramMB: Int?
    var cpuPct: Double?
    var tps: Double?
}
