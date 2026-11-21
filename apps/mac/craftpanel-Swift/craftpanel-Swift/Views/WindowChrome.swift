import SwiftUI
import AppKit

/// Centres the red/yellow/green window buttons in a 52 pt title-bar strip (the height macOS gives a window with a toolbar),
/// instead of letting them hug the top edge of a hidden title bar. Re-applied whenever AppKit re-lays the title bar out.
struct WindowChrome: NSViewRepresentable {
    static let barHeight: CGFloat = 52
    /// Distance from the window's left edge to the close button.
    static let leftInset: CGFloat = 22

    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Resizes the title-bar container (pinned to the top) until the buttons' centre sits `barHeight / 2` below the window's top edge.
    @MainActor static func apply(to window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        func place(_ height: CGFloat) {
            container.setFrameSize(NSSize(width: container.frame.width, height: height))
            container.setFrameOrigin(NSPoint(x: container.frame.origin.x, y: window.frame.height - height))
            container.layoutSubtreeIfNeeded()
        }
        func fromTop() -> CGFloat { window.frame.height - close.convert(close.bounds, to: nil).midY }
        let target = barHeight / 2
        place(container.frame.height)
        let delta = target - fromTop()
        if abs(delta) > 0.5 { place(container.frame.height + delta) }
        // Shift the three buttons right by the same amount so they keep their spacing.
        let shift = leftInset - close.convert(close.bounds, to: nil).minX
        if abs(shift) > 0.5 {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let b = window.standardWindowButton(kind) { b.setFrameOrigin(NSPoint(x: b.frame.origin.x + shift, y: b.frame.origin.y)) }
            }
        }
    }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            WindowChrome.apply(to: window)
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                                              NSWindow.didChangeScreenNotification]
            for n in names {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: window, queue: .main) { [weak window] _ in
                    guard let window else { return }
                    MainActor.assumeIsolated { WindowChrome.apply(to: window) }
                })
            }
            // AppKit lays the title bar out once more right after the window shows.
            DispatchQueue.main.async { [weak window] in if let window { WindowChrome.apply(to: window) } }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
