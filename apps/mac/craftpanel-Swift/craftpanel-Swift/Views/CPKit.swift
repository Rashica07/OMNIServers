import SwiftUI

/// The pieces of the Tauri app's `ui.tsx` component kit this build didn't
/// already have a native counterpart for (`CPToggle`/`CPSlider`/
/// `CPSegmentedPicker`/`IconButton`/`Badge`/`SettingsCard` cover the rest —
/// see their own files). Every panel still on native `Form`/`List` chrome
/// gets converted onto these so the whole app reads as one visual system
/// instead of a native-Mac-Settings approximation of it.
///
/// Deliberately NOT touching `ServerDetailShell`'s Start/Stop capsule —
/// that's one of the two things kept byte-for-byte per explicit direction,
/// so it stays its own inline `Capsule()` rather than being folded into
/// `CPButtonStyle` below (whose shapes match `ui.tsx`'s actual
/// rounded-sm/md/lg buttons, not a pill).

// MARK: - Button

enum CPButtonVariant {
    case primary, secondary, ghost, subtle, quiet, danger
}

enum CPButtonSize {
    case sm, md, lg

    var height: CGFloat { self == .sm ? 26 : self == .md ? 30 : 38 }
    var hPad: CGFloat { self == .sm ? 9 : self == .md ? 11 : 15 }
    var font: Font { self == .sm ? .system(size: 11, weight: .medium) : self == .md ? .system(size: 12, weight: .medium) : .system(size: 13, weight: .medium) }
    var radius: CGFloat { self == .sm ? CPRadius.sm : self == .md ? CPRadius.md : CPRadius.lg }
}

/// A `ButtonStyle`, not a wrapper view — composes with `Label`, `.disabled`,
/// loading spinners, anything a plain `Button` already does. Direct visual
/// port of `ui.tsx`'s `BTN_VARIANT`/`BTN_SIZE` tables.
struct CPButtonStyle: ButtonStyle {
    var variant: CPButtonVariant = .ghost
    var size: CPButtonSize = .md
    var block: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        // Destructive-role buttons read as danger unless a variant was chosen explicitly.
        let v: CPButtonVariant = configuration.role == .destructive && (variant == .secondary || variant == .ghost) ? .danger : variant
        CPButtonBody(configuration: configuration, variant: v, size: size, block: block)
    }

    /// App-wide default for any Button that doesn't pick a style itself.
    static let appDefault = CPButtonStyle(variant: .secondary, size: .md, block: false)
}

private struct CPButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: CPButtonVariant
    let size: CPButtonSize
    let block: Bool
    @State private var hovering = false
    @State private var shakes: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(fg)
            .padding(.horizontal, size.hPad)
            .frame(height: size.height)
            .frame(maxWidth: block ? .infinity : nil)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .strokeBorder(border, lineWidth: border == .clear ? 0 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            // Whole button hit-testable, even the clear-background variants.
            .contentShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(block ? 1 : (configuration.isPressed ? 0.97 : (hovering && isEnabled ? 1.02 : 1)))
            .modifier(WhooshEffect(travel: block ? 0 : 0.014, progress: shakes))
            .onHover { hovering = $0 }
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { withAnimation(CPMotion.whoosh) { shakes += 1 } }
            }
            .animation(.spring(response: 0.45, dampingFraction: 1), value: hovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }

    private var fg: Color {
        switch variant {
        case .primary: CPColor.onAccent
        case .secondary, .ghost, .subtle: CPColor.ink
        case .quiet: hovering ? CPColor.ink : CPColor.inkDim
        case .danger: CPColor.bad
        }
    }

    private var bg: Color {
        switch variant {
        case .primary: hovering ? CPColor.accentHover : CPColor.accent
        case .secondary: hovering ? CPColor.surface4 : CPColor.surface3
        case .ghost: hovering ? CPColor.surface3 : CPColor.surface2
        case .subtle: hovering ? CPColor.surface4 : CPColor.surface3
        case .quiet: hovering ? CPColor.surface2 : .clear
        case .danger: hovering ? CPColor.bad.opacity(0.12) : .clear
        }
    }

    private var border: Color {
        switch variant {
        case .secondary: hovering ? CPColor.lineStrong : CPColor.line
        case .ghost: hovering ? CPColor.lineStrong : CPColor.line
        case .danger: hovering ? CPColor.bad.opacity(0.6) : CPColor.bad.opacity(0.35)
        case .primary, .subtle, .quiet: .clear
        }
    }
}

extension View {
    /// `.buttonStyle(.cp(.primary))` — matches `.buttonStyle(.plain)`'s
    /// call shape so swapping a hand-rolled button over is a one-line diff.
    func cpButton(_ variant: CPButtonVariant = .ghost, size: CPButtonSize = .md, block: Bool = false) -> some View {
        self.buttonStyle(CPButtonStyle(variant: variant, size: size, block: block))
    }
}

// MARK: - Field

/// Label + control + hint/error — direct port of `ui.tsx`'s `Field`.
struct CPField<Content: View>: View {
    let label: String
    var hint: String?
    var error: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CPColor.inkDim)
            content()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(CPColor.bad)
            } else if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(CPColor.inkFaint)
            }
        }
    }
}

// MARK: - Banner

enum CPTone {
    case neutral, accent, ok, warn, bad, info

    var fg: Color {
        switch self {
        case .neutral: CPColor.inkDim
        case .accent: CPColor.accentSoft
        case .ok: CPColor.okSoft
        case .warn: CPColor.warnSoft
        case .bad: CPColor.badSoft
        case .info: CPColor.infoSoft
        }
    }
    var bg: Color {
        switch self {
        case .neutral: CPColor.surface3
        case .accent: CPColor.accentMuted
        case .ok: CPColor.ok.opacity(0.12)
        case .warn: CPColor.warn.opacity(0.12)
        case .bad: CPColor.bad.opacity(0.12)
        case .info: CPColor.info.opacity(0.12)
        }
    }
    var line: Color { fg.opacity(0.35) }
    var glyph: String {
        switch self {
        case .neutral: "info.circle"
        case .accent: "sparkles"
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .bad: "exclamationmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }
}

/// Inline status strip — direct port of `ui.tsx`'s `Banner`, replacing the
/// ad-hoc `Label(...).foregroundStyle(CPColor.warn)` error lines repeated
/// across nearly every panel.
struct CPBanner<Actions: View>: View {
    var tone: CPTone = .neutral
    var title: String?
    var icon: String?
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon ?? tone.glyph)
                .font(.system(size: 13))
                .foregroundStyle(tone.fg)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CPColor.ink)
                }
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(CPColor.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tone.bg)
        .overlay(
            RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous)
                .strokeBorder(tone.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous))
    }
}

extension CPBanner where Actions == EmptyView {
    init(tone: CPTone = .neutral, title: String? = nil, icon: String? = nil, message: String? = nil) {
        self.init(tone: tone, title: title, icon: icon, message: message) { EmptyView() }
    }
}

// MARK: - Empty state

/// Icon + title + body + optional action — direct port of `ui.tsx`'s
/// `EmptyState`, replacing raw `ContentUnavailableView` so empty states
/// match OMNIServers's own look instead of macOS's default one.
struct CPEmptyState<Action: View>: View {
    var icon: String = "shippingbox"
    let title: String
    var message: String?
    var tone: CPTone = .neutral
    var compact: Bool = false
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            ZStack {
                RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous)
                    .fill(CPColor.surface2)
                    .frame(width: compact ? 40 : 56, height: compact ? 40 : 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous)
                            .strokeBorder(CPColor.lineSoft, lineWidth: 1)
                    )
                Image(systemName: icon)
                    .font(.system(size: compact ? 18 : 24))
                    .foregroundStyle(tone.fg)
            }
            Text(title)
                .font(CPFont.display(compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(CPColor.ink)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(CPColor.inkFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            action()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 20 : 44)
        .frame(maxWidth: .infinity)
    }
}

extension CPEmptyState where Action == EmptyView {
    init(icon: String = "shippingbox", title: String, message: String? = nil, tone: CPTone = .neutral, compact: Bool = false) {
        self.init(icon: icon, title: title, message: message, tone: tone, compact: compact) { EmptyView() }
    }
}

// MARK: - State block

enum CPState { case loading, empty, error, offline }

/// One component for loading/empty/error/offline — direct port of
/// `ui.tsx`'s `StateBlock`, so panels stop hand-rolling "Loading…" text.
struct CPStateBlock: View {
    let state: CPState
    var title: String?
    var message: String?
    var compact: Bool = false
    var onRetry: (() -> Void)?

    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(title ?? "Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(CPColor.inkFaint)
            }
            .padding(.vertical, compact ? 24 : 56)
            .frame(maxWidth: .infinity)
        case .error:
            CPEmptyState(icon: "exclamationmark.octagon.fill", title: title ?? "Something went wrong", message: message, tone: .bad, compact: compact) {
                if let onRetry {
                    Button("Try again", systemImage: "arrow.clockwise", action: onRetry)
                        .cpButton(.secondary)
                }
            }
        case .offline:
            CPEmptyState(icon: "bolt.slash", title: title ?? "Server isn't running", message: message ?? "Start the server to see this.", tone: .warn, compact: compact)
        case .empty:
            CPEmptyState(title: title ?? "Nothing here yet", message: message, compact: compact)
        }
    }
}


/// Underline tab bar (`ui.tsx` `Tabs`): icon + label, accent underline on
/// the active tab. Generic over the tab id.
struct CPTabBar<ID: Hashable>: View {
    let tabs: [(id: ID, label: String, symbol: String)]
    @Binding var selection: ID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.id) { tab in
                    let active = tab.id == selection
                    Button { withAnimation(CPMotion.fast) { selection = tab.id } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.symbol).font(.system(size: 11, weight: .medium))
                            Text(tab.label).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(active ? CPColor.ink : CPColor.inkFaint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(active ? CPColor.accent : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
    }
}

/// A labelled row with a trailing control and a faint hint — the
/// `<label className="flex justify-between border-t">` pattern in SettingsPage.
struct CPSettingRow<Control: View>: View {
    let title: String
    var hint: String?
    var divider = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(CPColor.lineSoft).frame(height: 1).padding(.bottom, 12) }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(CPColor.ink)
                    if let hint {
                        Text(hint).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control()
            }
        }
    }
}


// MARK: - Tap feedback for plain buttons

/// For icon buttons, tabs and rail tiles: grows a touch on hover, dips on press and gives a slight shake when clicked.
struct CPTapStyle: ButtonStyle {
    var hoverScale: CGFloat = 1.06
    var shake = true
    func makeBody(configuration: Configuration) -> some View {
        CPTapBody(configuration: configuration, hoverScale: hoverScale, shake: shake)
    }
}

private struct CPTapBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverScale: CGFloat
    let shake: Bool
    @State private var hovering = false
    @State private var shakes: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : (hovering && isEnabled ? hoverScale : 1))
            .modifier(WhooshEffect(travel: 0.014, progress: shakes))
            .onHover { hovering = $0 }
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && shake { withAnimation(CPMotion.whoosh) { shakes += 1 } }
            }
            .animation(.spring(response: 0.45, dampingFraction: 1), value: hovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

extension View {
    /// Hover grow + press dip + slight shake on click.
    func cpTap(hoverScale: CGFloat = 1.06, shake: Bool = true) -> some View { buttonStyle(CPTapStyle(hoverScale: hoverScale, shake: shake)) }
}


// MARK: - Whoosh

extension CPMotion {
    /// Slow, smooth, non-linear: eases in, glides, eases out.
    static let whoosh = Animation.timingCurve(0.45, 0.0, 0.2, 1.0, duration: 0.8)
}

/// One soft, slow swell (a slight zoom in and back, no movement), driven by a counter that goes up by 1 per click.
/// While the counter moves from n to n+1 the scale rises smoothly and returns to exactly 1.
struct WhooshEffect: GeometryEffect {
    var travel: CGFloat   // peak growth, e.g. 0.015 = 1.5 %
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let frac = progress - progress.rounded(.down)
        let k = 1 + travel * sin(frac * .pi)
        let t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: k, y: k)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(t)
    }
}
