import Testing
import AppKit
@testable import craftpanel_Swift

@MainActor
struct WindowChromeTests {
    @Test func buttonsEndUpCentredInTheTallerBar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let close = window.standardWindowButton(.closeButton)!
        let before = close.convert(close.bounds, to: nil).midY
        WindowChrome.apply(to: window)
        let after = close.convert(close.bounds, to: nil).midY
        let fromTop = window.frame.height - after
        #expect(abs(close.convert(close.bounds, to: nil).minX - WindowChrome.leftInset) < 1)
        WindowChrome.apply(to: window)
        #expect(abs(close.convert(close.bounds, to: nil).minX - WindowChrome.leftInset) < 1) // stable when re-applied
        #expect(after < before)                              // moved down from the top edge
        #expect(abs(fromTop - WindowChrome.barHeight / 2) < 3) // centred in the bar
    }
}
