import SwiftUI
import AppKit

/// A real syntax-highlighting text editor for the Files tab, backed by
/// `NSTextView` and `ConfigHighlighter`. The Tauri version fakes this
/// with the "transparent textarea over a colored `<pre>`, scroll-synced"
/// CSS trick — a reasonable move for a webview with no native text
/// system, but AppKit already has one, so this recolors the real
/// `NSTextStorage` in place instead: no second scroll-synced layer to
/// drift out of alignment, real system-font metrics, real cursor/
/// selection rendering. A genuine native win, not just a reskin.
struct SyntaxTextView: NSViewRepresentable {
    @Binding var text: String
    let lang: ConfigLang

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = HighlightingTextView()
        textView.delegate = context.coordinator
        textView.lang = lang
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(CPColor.ink)
        textView.backgroundColor = NSColor(CPColor.surface2)
        textView.insertionPointColor = NSColor(CPColor.ink)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        // `wrap="off"` on the Tauri side — long config lines scroll
        // horizontally instead of wrapping, which keeps indentation and
        // alignment intact while editing.
        textView.textContainer?.widthTracksTextView = false
        let unbounded = CGFloat.greatestFiniteMagnitude
        textView.textContainer?.containerSize = NSSize(width: unbounded, height: unbounded)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(CPColor.surface2)
        scrollView.documentView = textView

        context.coordinator.textView = textView
        textView.highlightAll()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.lang != lang {
            textView.lang = lang
            textView.highlightAll()
        }
        // Only push external changes in (e.g. switching which file is
        // open) — not on every keystroke, which would fight the
        // coordinator's own edits and reset the cursor/undo stack.
        if textView.string != text {
            textView.string = text
            textView.highlightAll()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: HighlightingTextView?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? HighlightingTextView else { return }
            text.wrappedValue = tv.string
            tv.highlightAll()
        }
    }
}

/// The `NSTextView` subclass doing the actual recoloring. Kept
/// `isRichText = false` so paste/typing never smuggles in foreign
/// formatting — `highlightAll()` is the *only* place attributes get set,
/// same "one source of truth, recomputed from scratch" shape as the TS
/// tokenizer it mirrors.
final class HighlightingTextView: NSTextView {
    var lang: ConfigLang = .plain

    func highlightAll() {
        guard let storage = textStorage else { return }
        let full = string as NSString
        // Same size cap in spirit as the tokenizer's own "never throws":
        // past a couple MB, recoloring every keystroke would make typing
        // laggy, so it degrades to plain monospaced text instead of
        // fighting the user.
        guard full.length < 2_000_000 else { return }

        let savedSelection = selectedRanges
        storage.beginEditing()

        let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor(CPColor.ink),
        ], range: NSRange(location: 0, length: storage.length))

        var offset = 0
        for lineSub in full.components(separatedBy: "\n") {
            let line = lineSub as NSString
            var col = offset
            for token in ConfigHighlighter.highlightLine(lineSub, lang: lang) {
                let len = (token.text as NSString).length
                if let cls = token.cls, len > 0 {
                    var attrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor(cls.color),
                        .font: cls.semibold ? boldFont : baseFont,
                    ]
                    if cls.italic { attrs[.obliqueness] = 0.15 }
                    let range = NSRange(location: col, length: len)
                    if range.location + range.length <= storage.length {
                        storage.setAttributes(attrs, range: range)
                    }
                }
                col += len
            }
            offset += line.length + 1
        }

        storage.endEditing()
        selectedRanges = savedSelection
    }
}
