import SwiftUI

/// A pill-style segmented control matching Tauri's own `Segmented`
/// component — stock SwiftUI `.pickerStyle(.segmented)` renders as a
/// thin, colorless `NSSegmentedControl` on macOS that reads as
/// noticeably plainer than the web app's rounded, weighted pill.
struct CPSegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String, symbol: String?)]

    init(selection: Binding<T>, options: [(value: T, label: String, symbol: String?)]) {
        self._selection = selection
        self.options = options
    }

    init(selection: Binding<T>, labels: [(T, String)]) {
        self._selection = selection
        self.options = labels.map { ($0.0, $0.1, nil) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                        }
                        Text(option.label).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .background(selection == option.value ? CPColor.surface4 : Color.clear)
                    .foregroundStyle(selection == option.value ? CPColor.ink : CPColor.inkFaint)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(CPColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
