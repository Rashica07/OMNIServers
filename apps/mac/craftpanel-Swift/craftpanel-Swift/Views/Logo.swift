import SwiftUI

/// The OMNIServers lockup: a pixel-cut "block" mark next to the wordmark.
/// Direct geometric port of `Logo.tsx`'s `LogoMark` SVG (same three-face
/// isometric cube, same two punched-out "pixels" on top) — the mark is
/// the only place the Minecraft reference is literal, so the rest of the
/// chrome stays round and calm.
struct LogoMark: View {
    var size: CGFloat = 26

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 32

            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

            // Top face (lightest — accentHover) — isometric diamond
            var top = Path()
            top.move(to: pt(16, 3))
            top.addLine(to: pt(28, 9))
            top.addLine(to: pt(16, 15))
            top.addLine(to: pt(4, 9))
            top.closeSubpath()
            context.fill(top, with: .color(CPColor.accentHover))

            // Right face (gradient hover -> press)
            var right = Path()
            right.move(to: pt(16, 15))
            right.addLine(to: pt(28, 9))
            right.addLine(to: pt(28, 23))
            right.addLine(to: pt(16, 29))
            right.closeSubpath()
            context.fill(right, with: .linearGradient(
                Gradient(colors: [CPColor.accentHover, CPColor.accentPress]),
                startPoint: pt(16, 9), endPoint: pt(16, 29)
            ))

            // Left face (darkened — a flat multiply-black overlay on the mark color)
            var left = Path()
            left.move(to: pt(4, 9))
            left.addLine(to: pt(16, 15))
            left.addLine(to: pt(16, 29))
            left.addLine(to: pt(4, 23))
            left.closeSubpath()
            context.fill(left, with: .color(CPColor.accentPress.opacity(0.65)))

            // Two "pixels" punched out of the top face
            let pixel1 = Path(CGRect(x: pt(13, 8.5).x, y: pt(13, 8.5).y, width: 3.2 * s, height: 1.7 * s))
            let pixel2 = Path(CGRect(x: pt(18, 11).x, y: pt(18, 11).y, width: 3.2 * s, height: 1.7 * s))
            context.fill(pixel1, with: .color(.white.opacity(0.36)))
            context.fill(pixel2, with: .color(.white.opacity(0.36)))
            _ = (pixel1, pixel2)
        }
        .frame(width: size, height: size)
    }
}

/// "OMNI" in ink, "Servers" in the brand accent — direct port of
/// `Logo.tsx`'s `Wordmark`.
struct Wordmark: View {
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            LogoMark(size: size)
            (Text("OMNI").foregroundStyle(CPColor.ink) + Text("Servers").foregroundStyle(CPColor.accent))
                .font(CPFont.display(size * 0.62, weight: .semibold))
        }
    }
}
