import SwiftUI
import AppKit

/// Small "it worked" notices: copied, saved, started. Separate from the
/// player notices in `PlayerNotifier`, which are clickable and per-server.
@MainActor @Observable
final class Toasts {
    static let shared = Toasts()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
        let symbol: String
        let isError: Bool
    }

    private(set) var items: [Item] = []

    func show(_ title: String, detail: String = "", symbol: String = "checkmark.circle.fill", error: Bool = false) {
        guard !isRunningUnitTests else { items.append(Item(title: title, detail: detail, symbol: symbol, isError: error)); return }
        // Same message twice in a row just restarts the timer instead of stacking.
        if let dup = items.first(where: { $0.title == title && $0.detail == detail }) { dismiss(dup.id) }
        let item = Item(title: title, detail: detail, symbol: symbol, isError: error)
        items.append(item)
        if items.count > 3 { items.removeFirst(items.count - 3) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(error ? 5 : 2.5))
            self.dismiss(item.id)
        }
    }

    func error(_ title: String, detail: String = "") {
        show(title, detail: detail, symbol: "exclamationmark.triangle.fill", error: true)
    }

    func dismiss(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Puts text on the clipboard and says so.
    func copy(_ text: String, what: String, detail: String = "") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("\(what) copied", detail: detail, symbol: "doc.on.clipboard.fill")
    }
}
