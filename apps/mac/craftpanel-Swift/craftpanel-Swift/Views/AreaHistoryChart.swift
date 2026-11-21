import SwiftUI
import Charts

/// A filled-area history chart with "latest X / peak Y" readouts below —
/// direct visual port of `AreaChart.tsx`, reused by the player-activity
/// and server-performance-history cards. Real Swift Charts + real
/// accessibility, same "native win" reasoning as `HealthStripView`'s
/// sparklines.
///
/// `detailed` is the full-size mode used on the Performance tab: a fixed time window (so the line
/// grows across the chart instead of stretching), gridlines with value labels, a dot on the latest
/// point and a hover readout.
struct AreaHistoryChart: View {
    struct Point: Identifiable {
        let id: Int64
        let value: Double?
        init(ts: Int64, value: Double?) { id = ts; self.value = value }
    }

    let points: [Point]
    let color: Color
    var yMax: Double?
    let formatValue: (Double) -> String
    var emptyMessage = "No data yet"
    var detailed = false
    var window: ClosedRange<Int64>?
    @State private var hoverTS: Int64?

    private var nonNilValues: [Double] { points.compactMap(\.value) }
    private var top: Double { max(yMax ?? ((nonNilValues.max() ?? 1) * 1.15), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if nonNilValues.isEmpty {
                Text(emptyMessage)
                    .font(.caption2)
                    .foregroundStyle(CPColor.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: detailed ? 140 : 80)
            } else if detailed {
                detailedChart
            } else {
                compactChart
                readouts
            }
        }
    }

    private var readouts: some View {
        HStack {
            Text("latest \(formatValue(nonNilValues.last ?? 0))")
            Spacer()
            Text("peak \(formatValue(nonNilValues.max() ?? 0))")
        }
        .font(.caption2)
        .foregroundStyle(CPColor.inkFaint)
    }

    private var compactChart: some View {
        Chart(points) { point in
            if let v = point.value {
                AreaMark(x: .value("t", point.id), y: .value("v", v))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", point.id), y: .value("v", v))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...max(yMax ?? (nonNilValues.max() ?? 1), 1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 80)
    }

    private var domainX: ClosedRange<Int64> {
        window ?? ((points.first?.id ?? 0)...max((points.last?.id ?? 1), (points.first?.id ?? 0) + 1))
    }

    private var hovered: Point? {
        guard let hoverTS else { return nil }
        return points.filter { $0.value != nil }.min { abs($0.id - hoverTS) < abs($1.id - hoverTS) }
    }

    private var detailedChart: some View {
        Chart {
            ForEach(points) { point in
                if let v = point.value {
                    AreaMark(x: .value("t", point.id), y: .value("v", v))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", point.id), y: .value("v", v))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let last = points.last(where: { $0.value != nil }), let v = last.value {
                PointMark(x: .value("t", last.id), y: .value("v", v))
                    .symbolSize(46).foregroundStyle(color)
            }
            if let h = hovered, let v = h.value {
                RuleMark(x: .value("t", h.id))
                    .foregroundStyle(CPColor.inkFaint.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(formatValue(v))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(CPColor.surface3, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(CPColor.ink)
                    }
            }
        }
        .chartXScale(domain: domainX)
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4])).foregroundStyle(CPColor.line)
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(formatValue(d)).font(.system(size: 10, design: .monospaced)).foregroundStyle(CPColor.inkFaint)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            if let frame = proxy.plotFrame {
                                let x = loc.x - geo[frame].origin.x
                                hoverTS = proxy.value(atX: x, as: Int64.self)
                            }
                        case .ended: hoverTS = nil
                        }
                    }
            }
        }
        .frame(height: 150)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.2), value: points.count)
    }
}
