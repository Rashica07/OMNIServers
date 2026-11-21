import SwiftUI
import SwiftData

/// "Server performance" — RAM/CPU/TPS over time, sampled about once a
/// minute while the server's running by `MetricsSampler`. This is the
/// "figure out exactly when it crashed or why it was lagging" view — the
/// console's health strip only ever shows right now. Direct port of
/// `ServerMetricsHistory.tsx`.
struct ServerMetricsHistoryCard: View {
    let server: ServerRecord

    @Environment(\.modelContext) private var modelContext
    @State private var range: HistoryRange = .h24
    @State private var points: [MetricPoint]?

    var body: some View {
        SettingsCard(title: "Server performance", symbol: "gauge.with.dots.needle.67percent",
                     description: "Sampled about once a minute while the server's running — a slow drift in RAM or a TPS dip shows up here even after you've moved on.") {
            CPSegmentedPicker(selection: $range, labels: HistoryRange.allCases.map { ($0, $0.label) })
                .frame(maxWidth: 220)

            if let points {
                if points.isEmpty {
                    Text("No samples yet — give it a bit while the server's running.")
                        .font(.caption2).foregroundStyle(CPColor.inkFaint)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MEMORY").font(.caption2.weight(.semibold)).foregroundStyle(CPColor.inkFaint)
                        AreaHistoryChart(
                            points: points.map { .init(ts: $0.ts, value: $0.ramMB.map(Double.init)) },
                            color: CPColor.accent, yMax: Double(server.ramMB),
                            formatValue: { String(format: "%.1f GB", $0 / 1024) }
                        )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CPU").font(.caption2.weight(.semibold)).foregroundStyle(CPColor.inkFaint)
                        AreaHistoryChart(
                            points: points.map { .init(ts: $0.ts, value: $0.cpuPct) },
                            color: CPColor.info,
                            formatValue: { "\(Int($0))%" }
                        )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TPS").font(.caption2.weight(.semibold)).foregroundStyle(CPColor.inkFaint)
                        AreaHistoryChart(
                            points: points.map { .init(ts: $0.ts, value: $0.tps) },
                            color: CPColor.ok, yMax: 20,
                            formatValue: { String(format: "%.1f", $0) },
                            emptyMessage: "No TPS data — needs RCON set up on this server."
                        )
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(server.id)-\(range.rawValue)") { reload() }
    }

    private func reload() {
        let since = Int64(Date().timeIntervalSince1970) - range.spanSecs
        points = MetricsSampler.history(context: modelContext, serverID: server.id, since: since)
    }
}
