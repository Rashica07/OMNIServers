import SwiftUI

/// Icon + title + description header wrapping a body — the SwiftUI
/// counterpart of the Tauri app's own `Card` component (`ui.tsx`), used
/// so every settings surface actually matches its visual language
/// instead of falling back to a flat `Form` `Section` with no icon or
/// description. `ScrollView` + `LazyVStack` of these replaces `Form`
/// entirely on this screen — `Form`'s own `Section` styling has no room
/// for a card header at all.
struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    var description: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(CPColor.accentMuted)
                        .frame(width: 30, height: 30)
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CPColor.accentSoft)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CPFont.display(14, weight: .semibold))
                        .foregroundStyle(CPColor.ink)
                    if let description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(CPColor.inkFaint)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
        }
        .background(CPColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CPRadius.xl, style: .continuous)
                .strokeBorder(CPColor.lineSoft, lineWidth: 1)
        )
    }
}

/// A labeled checkbox/toggle row with an optional faint trailing note —
/// the shape almost every Automation-card row uses (`<label><input
/// type=checkbox>…</label>` on the web side).
struct CardToggleRow<Trailing: View>: View {
    let label: String
    @Binding var isOn: Bool
    var note: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label)
                    trailing()
                }
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(CPColor.inkFaint)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

extension CardToggleRow where Trailing == EmptyView {
    init(label: String, isOn: Binding<Bool>, note: String? = nil) {
        self.init(label: label, isOn: isOn, note: note) { EmptyView() }
    }
}
