import SwiftUI
import Charts

/// Live Memory / CPU / Tick-rate strip at the top of the console — direct
/// match for the Tauri app's `HealthStrip.tsx`, and the exact gap a
/// side-by-side screenshot comparison against the real app surfaced.
///
/// Swift Charts instead of a hand-rolled SVG sparkline (`Spark` in the
/// web source) is the plan's own explicit "native win" call-out for this
/// exact spot — real accessibility support and animation, far less code.
struct HealthStripView: View {
    let record: ServerRecord
    let pid: Int32?
    let isRunning: Bool

    private static let keep = 48
    /// Starts as an all-`nil` sample, not an optional strip — so the real
    /// cards (icon, label, "—" placeholder value, empty sparkline) render
    /// from the very first frame. The previous design swapped in three
    /// blank `RoundedRectangle`s while `sample` was `nil`, which — on a
    /// dark surface color close to the console well behind it — read as
    /// solid black boxes with no content at all, the exact gap a
    /// side-by-side screenshot comparison against the real app surfaced.
    @State private var sample = PerfSample()
    @State private var ramHistory: [Double] = []
    @State private var cpuHistory: [Double] = []
    @State private var tpsHistory: [Double] = []
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isRunning {
                HStack(spacing: 10) {
                    StatCard(
                        icon: "memorychip", label: "Memory",
                        value: sample.ramMB.map { String(format: "%.1f", Double($0) / 1024) } ?? "—",
                        unit: sample.ramMB != nil ? "GB" : nil,
                        history: ramHistory, maxValue: max(1024, ramHistory.max() ?? 0) * 1.15 / 1024,
                        color: CPColor.accent, tone: nil,
                        help: "How much RAM the server process is using right now. Climbing steadily and never dropping usually means a mod is leaking."
                    )
                    StatCard(
                        icon: "cpu", label: "CPU",
                        value: sample.cpuPct.map { String(format: "%.0f", $0) } ?? "—",
                        unit: sample.cpuPct != nil ? "%" : nil,
                        history: cpuHistory, maxValue: max(100, cpuHistory.max() ?? 0),
                        color: CPColor.info, tone: cpuTone,
                        help: "Share of one CPU core. Above 100% just means it's using more than one core — that's normal for a busy server."
                    )
                    StatCard(
                        icon: "gauge.with.dots.needle.67percent", label: "Tick rate",
                        value: sample.tps.map { String(format: "%.1f", $0) } ?? (sample.source != nil ? "—" : "n/a"),
                        unit: sample.tps.map { _ in sample.mspt.map { "tps · \(String(format: "%.1f", $0))ms" } ?? "tps" },
                        history: tpsHistory, maxValue: 20,
                        color: CPColor.ok, tone: tpsTone,
                        help: "20 tps is perfect. Below 15 and players feel it as lag — usually too many mobs, a heavy mod, or not enough memory."
                    )
                }
            }
        }
        .task(id: record.id) {
            ramHistory = []; cpuHistory = []; tpsHistory = []; sample = PerfSample()
            guard isRunning else { return }
            await poll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await poll()
            }
        }
    }

    private var tpsTone: StatCard.Tone? {
        guard let tps = sample.tps else { return nil }
        return tps >= 19 ? .ok : tps >= 15 ? .warn : .bad
    }

    private var cpuTone: StatCard.Tone? {
        guard let cpu = sample.cpuPct else { return nil }
        return cpu >= 90 ? .warn : nil
    }

    private func poll() async {
        let s = await PerfSampler.sample(record: record, pid: pid, isRunning: isRunning)
        sample = s
        if let ram = s.ramMB { push(&ramHistory, Double(ram)) }
        if let cpu = s.cpuPct { push(&cpuHistory, cpu) }
        if let tps = s.tps { push(&tpsHistory, tps) }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > Self.keep { arr.removeFirst(arr.count - Self.keep) }
    }
}

private struct StatCard: View {
    enum Tone { case ok, warn, bad }

    let icon: String
    let label: String
    let value: String
    let unit: String?
    let history: [Double]
    let maxValue: Double
    let color: Color
    let tone: Tone?
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(CPColor.inkFaint)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(CPFont.display(17, weight: .semibold))
                    .foregroundStyle(toneColor)
                if let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(CPColor.inkFaint)
                }
            }

            sparkline
                .frame(height: 30)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CPColor.line, lineWidth: 1))
        .help(help)
    }

    private var toneColor: Color {
        switch tone {
        case .ok: CPColor.ok
        case .warn: CPColor.warn
        case .bad: CPColor.bad
        case nil: CPColor.ink
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        if history.count < 2 {
            Color.clear
        } else {
            let points = Array(history.enumerated())
            Chart(points, id: \.offset) { point in
                AreaMark(x: .value("i", point.offset), y: .value("v", point.element))
                    .foregroundStyle(
                        LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("i", point.offset), y: .value("v", point.element))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...max(maxValue, 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        }
    }
}
