import SwiftUI
import SwiftData

/// Performance tab: live CPU, memory and uptime tiles, and a graph over the last minute up to a week.
/// Short ranges draw from a 2-second sampler that runs while this tab is open; longer ones from the
/// per-minute history `MetricsSampler` stores.
struct PerformanceView: View {
    let server: ServerRecord
    let runtime: ServerRuntime

    @Environment(\.modelContext) private var modelContext
    @State private var range: PerformanceChart.Range = .m5
    @State private var live: [(ts: Int64, ramMB: Double, cpu: Double)] = []
    @State private var stored: [MetricPoint] = []
    @State private var now = Date()

    private var running: Bool { runtime.snapshot.status == .running }
    private var latest: (ramMB: Double, cpu: Double)? { live.last.map { ($0.ramMB, $0.cpu) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !running && series.isEmpty && range.isLive {
                    offState
                } else {
                    tiles
                    graphCard
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .task(id: runtime.snapshot.pid) { await pollLive() }
        .task(id: range) { reloadStored() }
    }

    private var tiles: some View {
        HStack(spacing: 12) {
            tile("CPU", running && latest != nil ? String(format: "%.1f%%", latest!.cpu) : "—", bar: running ? latest.map { min(1, $0.cpu / 100) } : nil)
            tile("Memory", running && latest != nil ? String(format: "%.1f of %.1f GB", latest!.ramMB / 1024, Double(server.ramMB) / 1024) : "—",
                 bar: running ? latest.map { min(1, $0.ramMB / Double(max(1, server.ramMB))) } : nil)
            tile("Uptime", running ? PerformanceChart.uptime(since: runtime.snapshot.startedAt, now: now) : "—", bar: nil)
        }
    }

    /// Nothing to measure yet: one calm card instead of empty tiles over an empty graph.
    private var offState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 26, weight: .light)).foregroundStyle(CPColor.inkFaint)
            Text("Server is off").font(.system(size: 15, weight: .semibold)).foregroundStyle(CPColor.ink)
            Text("Start it to see live CPU, memory and uptime. Longer history is kept for 1h, 24h and 7d.")
                .font(.system(size: 12)).foregroundStyle(CPColor.inkFaint).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                ForEach([PerformanceChart.Range.h1, .h24, .d7]) { r in
                    Button(r.rawValue) { range = r }.cpButton(.secondary, size: .sm)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48).padding(.horizontal, 20)
        .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous).strokeBorder(CPColor.line))
    }

    private func tile(_ title: String, _ value: String, bar: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
            Text(value).font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(CPColor.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            ZStack(alignment: .leading) {
                Capsule().fill(CPColor.surface3).frame(height: 4)
                GeometryReader { g in Capsule().fill(CPColor.accent).frame(width: g.size.width * (bar ?? 0), height: 4) }.frame(height: 4)
            }
            .opacity(bar == nil ? 0 : 1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.line))
    }

    private var graphCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage").font(.system(size: 13, weight: .medium)).foregroundStyle(CPColor.ink)
                Spacer()
                CPSegmentedPicker(selection: $range, labels: PerformanceChart.Range.allCases.map { ($0, $0.rawValue) }).frame(maxWidth: 260)
            }
            if series.isEmpty {
                Text(running ? "Collecting data… the graph appears after a few seconds." : "No history for this range yet.")
                    .font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let end = Int64(now.timeIntervalSince1970)
                let win = (end - range.seconds)...end
                label("Memory"); AreaHistoryChart(points: series.map { .init(ts: $0.ts, value: $0.ramMB) }, color: CPColor.accent,
                                                  yMax: Double(server.ramMB), formatValue: { String(format: "%.1f GB", $0 / 1024) }, detailed: true, window: win)
                label("CPU"); AreaHistoryChart(points: series.map { .init(ts: $0.ts, value: $0.cpu) }, color: CPColor.info, formatValue: { "\(Int($0))%" }, detailed: true, window: win)
            }
        }
        .padding(16)
        .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.line))
    }

    private func label(_ s: String) -> some View { Text(s).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint) }

    private var series: [(ts: Int64, ramMB: Double?, cpu: Double?)] {
        let cutoff = Int64(Date().timeIntervalSince1970) - range.seconds
        if range.isLive { return live.filter { $0.ts >= cutoff }.map { ($0.ts, $0.ramMB, $0.cpu) } }
        return stored.map { ($0.ts, $0.ramMB.map(Double.init), $0.cpuPct) }
    }

    private func reloadStored() {
        guard !range.isLive else { return }
        stored = MetricsSampler.history(context: modelContext, serverID: server.id, since: Int64(Date().timeIntervalSince1970) - range.seconds)
    }

    private func pollLive() async {
        while !Task.isCancelled {
            now = Date()
            if running, let pid = runtime.snapshot.pid {
                let (ram, cpu) = PerfSampler.processSample(pid: pid)
                if let ram { live.append((Int64(now.timeIntervalSince1970), Double(ram), cpu ?? 0)) }
                if live.count > 150 { live.removeFirst(live.count - 150) }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
