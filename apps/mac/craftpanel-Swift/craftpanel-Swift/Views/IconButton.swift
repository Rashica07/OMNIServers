import SwiftUI

/// A small icon-only button with a comfortable, explicit hit target.
/// SwiftUI sizes an icon-only `Button`'s tappable area to the glyph's
/// tight bounding box by default — which is exactly the "you have to
/// click at just the right pixel" problem this fixes. Matches Tauri's
/// own `IconButton` component: same generous click area everywhere,
/// regardless of how small the glyph inside looks.
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 28
    var tint: Color = CPColor.inkFaint
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .cpTap(hoverScale: 1.12)
        .help(help ?? "")
    }
}
