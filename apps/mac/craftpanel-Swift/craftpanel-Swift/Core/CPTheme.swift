import SwiftUI
import CoreText

/// One complete set of `--cp-*` color tokens (see `src/index.css`).
struct CPPalette: Sendable {
    var bg, surface, surface2, surface3, surface4, console: UInt32
    var lineSoft, line, lineStrong: UInt32
    var ink, inkDim, inkFaint, inkGhost: UInt32
    var accent, accentHover, accentPress, accentSoft, accentMuted, onAccent: UInt32
    var ok, okSoft, okMuted, warn, warnSoft, warnMuted, bad, badSoft, badMuted, info, infoSoft, infoMuted: UInt32
    var isLight = false
}

/// The app themes, ported 1:1 from `theme.ts` / `index.css`. All four are free.
enum CPThemeID: String, CaseIterable, Identifiable, Sendable {
    case dark, light, midnight, sunset
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var palette: CPPalette {
        switch self {
        case .dark: .dark
        case .light: .light
        case .midnight:
            with(.dark) {
                $0.bg = 0x0a0e17; $0.surface = 0x10151f; $0.surface2 = 0x161c28; $0.surface3 = 0x1c2330
                $0.surface4 = 0x242c3b; $0.console = 0x070a10; $0.lineSoft = 0x1a212c; $0.line = 0x252d3a
                $0.lineStrong = 0x34404f; $0.ink = 0xeef1f5; $0.inkDim = 0xa8b0bd; $0.inkFaint = 0x838da0
                $0.inkGhost = 0x5f6878; $0.accent = 0x3ea6ff; $0.accentHover = 0x5cb6ff; $0.accentPress = 0x2b8fe0
                $0.accentSoft = 0x8fcaff; $0.accentMuted = 0x0d2438; $0.onAccent = 0x001322
            }
        case .sunset:
            // OMNI's warm black with Solar Gold as the accent instead of Imperial Crimson.
            with(.dark) {
                $0.accent = 0xe8b44f; $0.accentHover = 0xf0c46a; $0.accentPress = 0xcf9b36
                $0.accentSoft = 0xf0cb85; $0.accentMuted = 0x2e2210; $0.onAccent = 0x1a1200
            }
        }
    }

    /// Swatch colors for the theme picker: (bg, surface, accent).
    var swatch: (Color, Color, Color) {
        let p = palette
        return (Color(hex: p.bg), Color(hex: p.surface), Color(hex: p.accent))
    }
}

private func with(_ p: CPPalette, _ f: (inout CPPalette) -> Void) -> CPPalette {
    var c = p; f(&c); return c
}

extension CPPalette {
    // OMNI look: warm near-black, ivory ink, Imperial Crimson for the primary action, Solar Gold as the rare highlight.
    static let dark = CPPalette(
        bg: 0x0f0e0d, surface: 0x171513, surface2: 0x1c1a17, surface3: 0x221f1c, surface4: 0x2b2824, console: 0x0b0a09,
        lineSoft: 0x24211e, line: 0x34302b, lineStrong: 0x484239,
        ink: 0xe8dcc8, inkDim: 0xb9af9f, inkFaint: 0x948b7c, inkGhost: 0x6f685c,
        accent: 0xc83246, accentHover: 0xd94459, accentPress: 0xa8283a, accentSoft: 0xf0707f, accentMuted: 0x2a1216, onAccent: 0xffffff,
        ok: 0x5fbf7f, okSoft: 0x8fd6a5, okMuted: 0x12241a, warn: 0xe8b44f, warnSoft: 0xf0cb85, warnMuted: 0x2a2010,
        bad: 0xf0707f, badSoft: 0xf6a0aa, badMuted: 0x2b1214, info: 0x6aa6e8, infoSoft: 0x9cc3f0, infoMuted: 0x0d1b2c)

    static let light = CPPalette(
        bg: 0xfaf6ee, surface: 0xffffff, surface2: 0xf4eee2, surface3: 0xede3d0, surface4: 0xe0d3bc, console: 0x1e1a16,
        lineSoft: 0xece4d4, line: 0xddd2bc, lineStrong: 0xc7b99d,
        ink: 0x1e1a16, inkDim: 0x4a4137, inkFaint: 0x625849, inkGhost: 0x9a8f7e,
        accent: 0xc83246, accentHover: 0xa8283a, accentPress: 0x8f2230, accentSoft: 0xa8283a, accentMuted: 0xfbe9ec, onAccent: 0xffffff,
        ok: 0x176a35, okSoft: 0x115227, okMuted: 0xe4f2e8, warn: 0x8a5f00, warnSoft: 0x6e4c00, warnMuted: 0xfaf0d6,
        bad: 0xb0243a, badSoft: 0x8a1c2e, badMuted: 0xfbe6ea, info: 0x1f6fc4, infoSoft: 0x17558f, infoMuted: 0xe9f1fb,
        isLight: true)
}

/// OMNIServers's visual identity: the `--cp-*` tokens of the *active* theme.
/// Same static API as before (`CPColor.accent`), now reading the current
/// palette. The root view keys itself on the theme id, so switching themes
/// re-renders everything with the new values.
enum CPColor {
    nonisolated(unsafe) static var palette: CPPalette = .dark

    // MARK: Surfaces (bottom -> top)
    static var bg: Color { Color(hex: palette.bg) }
    static var surface: Color { Color(hex: palette.surface) }
    static var surface2: Color { Color(hex: palette.surface2) }
    static var surface3: Color { Color(hex: palette.surface3) }
    static var surface4: Color { Color(hex: palette.surface4) }
    static var console: Color { Color(hex: palette.console) }

    // MARK: Lines
    static var lineSoft: Color { Color(hex: palette.lineSoft) }
    static var line: Color { Color(hex: palette.line) }
    static var lineStrong: Color { Color(hex: palette.lineStrong) }

    // MARK: Ink
    static var ink: Color { Color(hex: palette.ink) }
    static var inkDim: Color { Color(hex: palette.inkDim) }
    static var inkFaint: Color { Color(hex: palette.inkFaint) }
    static var inkGhost: Color { Color(hex: palette.inkGhost) }

    // MARK: Accent
    static var accent: Color { Color(hex: palette.accent) }
    static var accentHover: Color { Color(hex: palette.accentHover) }
    static var accentPress: Color { Color(hex: palette.accentPress) }
    static var accentSoft: Color { Color(hex: palette.accentSoft) }
    static var accentMuted: Color { Color(hex: palette.accentMuted) }
    static var accentLine: Color { Color(hex: palette.accent).opacity(0.25) }
    static var accentRing: Color { Color(hex: palette.accent).opacity(0.4) }
    static var onAccent: Color { Color(hex: palette.onAccent) }

    // MARK: Semantic status
    static var ok: Color { Color(hex: palette.ok) }
    static var okSoft: Color { Color(hex: palette.okSoft) }
    static var okMuted: Color { Color(hex: palette.okMuted) }
    static var warn: Color { Color(hex: palette.warn) }
    static var warnSoft: Color { Color(hex: palette.warnSoft) }
    static var warnMuted: Color { Color(hex: palette.warnMuted) }
    static var bad: Color { Color(hex: palette.bad) }
    static var badSoft: Color { Color(hex: palette.badSoft) }
    static var badMuted: Color { Color(hex: palette.badMuted) }
    static var info: Color { Color(hex: palette.info) }
    static var infoSoft: Color { Color(hex: palette.infoSoft) }
    static var infoMuted: Color { Color(hex: palette.infoMuted) }
}

/// Motion tokens (`--cp-ease`, `--cp-t-*`): ease-out, nothing bouncy.
enum CPMotion {
    static let fast = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.12)
    static let base = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.16)
    static let slow = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.22)
}

/// Spacing: Tailwind's 4 px scale, which the web UI uses unmodified.
enum CPSpace {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32, s10: CGFloat = 40
    /// `--cp-control-h`
    static let controlH: CGFloat = 32
    static let sidebarWidth: CGFloat = 268
}

/// Type roles, ported from the web app's `--cp-font-*` stack. Display
/// text uses Space Grotesk — the web app's own bundled face (a variable
/// font, OFL) — registered from the app bundle at first use; if that ever
/// fails it falls back to SF Rounded. Body text stays the system font, as
/// on the web (`-apple-system`).
enum CPFont {
    private static let spaceGrotesk: String? = {
        guard let url = Bundle.main.url(forResource: "SpaceGrotesk", withExtension: "woff2") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let d = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first,
              let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { return nil }
        return name
    }()

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        guard let name = spaceGrotesk else { return .system(size: size, weight: weight, design: .rounded) }
        return .custom(name, fixedSize: size).weight(weight)
    }
    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, design: .monospaced)
    }
}

extension Color {
    /// `Color(hex: 0xff8c00)` -- the exact token values above, without a
    /// hand-typed `Color(red:green:blue:)` triplet per constant.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Corner radius scale, ported 1:1 from `index.css`'s `--cp-r-*` (macOS
/// values -- Windows' tighter `:root[data-os="win"]` overrides have no
/// counterpart here since this build only ever targets macOS).
enum CPRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 9
    static let md: CGFloat = 13
    static let lg: CGFloat = 17
    static let xl: CGFloat = 22
    static let xl2: CGFloat = 28
}

/// Depth, ported from `--cp-sh-1/2/3` -- each CSS token stacks two
/// box-shadows (a colored drop + a hairline inset highlight); SwiftUI's
/// `.shadow()` only draws the drop half per call, so these apply as two
/// stacked `.shadow()` modifiers to get the same layered softness. The
/// inset top highlight CSS adds has no cheap SwiftUI equivalent and is
/// skipped -- the drop shadows alone carry the "soft depth, never a hard
/// edge" feel these tokens are actually for.
extension View {
    /// Cards, dropdowns sitting on a surface -- `--cp-sh-1`.
    func cpShadowE1() -> some View {
        self.shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
    }
    /// Popovers, menus -- `--cp-sh-2`.
    func cpShadowE2() -> some View {
        self
            .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 4)
            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
    }
    /// Modals, the command palette -- `--cp-sh-3`.
    func cpShadowE3() -> some View {
        self
            .shadow(color: .black.opacity(0.4), radius: 22, x: 0, y: 18)
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)
    }
}
