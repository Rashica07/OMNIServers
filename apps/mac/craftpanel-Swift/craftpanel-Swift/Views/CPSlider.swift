import SwiftUI

/// A memory/RAM slider with a real filled track, matching Tauri's own
/// custom-styled `<input type=range>` — SwiftUI's stock `Slider` on
/// macOS renders as a thin, colorless groove with a tiny knob, which is
/// exactly what read as "weak" next to the web app's version.
struct CPSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// Small ticks drawn on the track (e.g. the RAM safe limit).
    var markers: [Double] = []

    var body: some View {
        GeometryReader { geo in
            let pct = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let width = geo.size.width
            let knobX = max(7, min(width - 7, width * pct))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(CPColor.surface3)
                    .frame(height: 7)
                Capsule()
                    .fill(CPColor.accent)
                    .frame(width: max(7, knobX), height: 7)
                ForEach(markers.filter { range.contains($0) }, id: \.self) { m in
                    Rectangle()
                        .fill(CPColor.inkFaint)
                        .frame(width: 2, height: 13)
                        .position(x: width * CGFloat((m - range.lowerBound) / (range.upperBound - range.lowerBound)), y: geo.size.height / 2)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(CPColor.accent, lineWidth: 2))
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let p = min(max(0, g.location.x / width), 1)
                    let raw = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
                    value = (raw / step).rounded() * step
                }
            )
        }
        .frame(height: 20)
    }
}
