import SwiftUI

/// OMNIServers's status marker: a small block, like the game's own, instead of a round dot.
/// A running server's block carries a soft glow of its colour, the one place the UI is allowed to shine.
struct StatusMarker: View {
    let color: Color
    var lit = false
    var size: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: lit ? color.opacity(0.55) : .clear, radius: lit ? 3 : 0)
    }
}
