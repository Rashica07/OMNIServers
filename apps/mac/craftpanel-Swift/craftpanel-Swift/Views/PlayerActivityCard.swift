import SwiftUI

/// "Player activity" — how many were on at once, bucketed over
/// 24h/7d/30d, so you can spot peak hours. Direct port of
/// `PlayerHistory.tsx`'s `PlayerActivityChart`, backed by
/// `PlayerAnalytics.concurrentSeries` (parsed straight from the logs —
/// no separate sampler needed, unlike the RAM/CPU/TPS history above).
struct PlayerActivityCard: View {
    let server: ServerRecord
    @Environment(ProcessManager.self) private var processes

    @State private var range: HistoryRange = .h24
    @State private var points: [ConcurrentPoint]?

    private var root: URL { URL(fileURLWithPath: server.path) }

    var body: some View {
        SettingsCard(title: "Player activity", symbol: "waveform.path.ecg",
                     description: "How many were on at once — spot your peak hours.") {
            CPSegmentedPicker(selection: $range, labels: HistoryRange.allCases.map { ($0, $0.label) })
                .frame(maxWidth: 220)

            if let points {
                AreaHistoryChart(
                    points: points.map { .init(ts: $0.ts, value: Double($0.count)) },
                    color: CPColor.accent,
                    formatValue: { "\(Int($0)) players" },
                    emptyMessage: "No player activity in this window."
                )
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(server.id)-\(range.rawValue)-\(processes.isRunning(server.id))") { reload() }
    }

    private func reload() {
        let since = Int64(Date().timeIntervalSince1970) - range.spanSecs
        let root = root, online = processes.isRunning(server.id), bucket = range.bucketSecs
        Task {
            points = await Task.detached(priority: .userInitiated) {
                PlayerAnalytics.concurrentSeries(serverDir: root, serverOnline: online, since: since, bucketSecsIn: bucket)
            }.value
        }
    }
}
