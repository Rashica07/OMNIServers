import SwiftUI

/// A pill switch matching Tauri's own `Toggle` component — stock macOS
/// `Toggle` renders as the system blue/green switch regardless of tint
/// in some contexts and reads as generic "OS chrome" next to the rest of
/// this app's custom-styled surfaces. This is the accent-colored,
/// rounded-pill switch used throughout the web app.
struct CPToggle: View {
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? CPColor.accent : CPColor.surface3)
                    .overlay(Capsule().strokeBorder(CPColor.line, lineWidth: isOn ? 0 : 1))
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 36, height: 20)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}
