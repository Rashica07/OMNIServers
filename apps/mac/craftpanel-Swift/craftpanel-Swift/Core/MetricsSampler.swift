import Foundation
import SwiftData

/// Background sampler: once a minute, snapshots RAM/CPU/TPS for every
/// *running* server and appends a row, so a chart can show usage over
/// the last 24h/7d/30d — not just the live-right-now numbers
/// `PerfSampler` already gives the console's health strip. Direct port
/// of `metrics_history.rs`'s `MetricsSampler`.
///
/// Deliberately coarse: one sample per server every 60s, not more often
/// — a multi-day chart doesn't need per-second resolution, and each
/// sample does a real process read plus one blocking-ish RCON round
/// trip per server.
@MainActor
final class MetricsSampler {
    static let shared = MetricsSampler(container: nil, processes: nil)

    private var container: ModelContainer?
    private var processes: ProcessManager?
    private var running = false

    static let tickSeconds: UInt64 = 60
    /// 30 days of minute-resolution samples — pruned on every tick.
    private static let retentionSecs: Int64 = 30 * 86_400

    private init(container: ModelContainer?, processes: ProcessManager?) {
        self.container = container
        self.processes = processes
    }

    /// The real container/processes aren't known until the app launches
    /// — `configure` wires them in once, then `start()` begins ticking.
    func configure(container: ModelContainer, processes: ProcessManager) {
        self.container = container
        self.processes = processes
    }

    func start() {
        guard !running, container != nil, processes != nil else { return }
        running = true
        Task { [weak self] in
            while let self, self.running {
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
                await self.tick()
            }
        }
    }

    private func tick() async {
        guard let container, let processes else { return }
        let context = ModelContext(container)
        guard let servers = try? context.fetch(FetchDescriptor<ServerRecord>()) else { return }
        let ts = Int64(Date().timeIntervalSince1970)

        for server in servers {
            let runtime = processes.runtime(for: server.id)
            guard runtime.snapshot.status == .running, let pid = runtime.snapshot.pid else { continue }

            let (ramMB, cpuPct) = PerfSampler.processSample(pid: pid)
            // TPS is opt-in on this same tick, not a separate poller —
            // silently skipped (not an error) if RCON isn't set up.
            let (tps, _, _) = await PerfSampler.tpsOverRCON(record: server)

            let sample = MetricSample(serverID: server.id, ts: ts, ramMB: ramMB.map(Int.init), cpuPct: cpuPct, tps: tps)
            context.insert(sample)
            PerformanceAlerts.shared.check(record: server, runtime: runtime, ramMB: ramMB, tps: tps)
        }

        try? context.save()
        pruneOldSamples(context: context, cutoff: ts - Self.retentionSecs)
    }

    private func pruneOldSamples(context: ModelContext, cutoff: Int64) {
        let old = FetchDescriptor<MetricSample>(predicate: #Predicate { $0.ts < cutoff })
        guard let stale = try? context.fetch(old) else { return }
        for sample in stale { context.delete(sample) }
        try? context.save()
    }

    // MARK: - Reading history for the chart

    /// Every sample for `serverID` since `since` (unix seconds), oldest first.
    static func history(context: ModelContext, serverID: UUID, since: Int64) -> [MetricPoint] {
        let descriptor = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.serverID == serverID && $0.ts >= since },
            sortBy: [SortDescriptor(\.ts, order: .forward)]
        )
        guard let samples = try? context.fetch(descriptor) else { return [] }
        return samples.map { MetricPoint(ts: $0.ts, ramMB: $0.ramMB, cpuPct: $0.cpuPct, tps: $0.tps) }
    }
}
