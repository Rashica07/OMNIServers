import Foundation

/// Keeps the Mac from sleeping while it's on AC power — an app-level
/// setting (not tied to any one server's lifetime), so a scheduled start
/// on a server that isn't running yet can actually fire: without this the
/// Mac could be asleep at the scheduled time with nothing there to notice.
///
/// **Native win**: the Rust side (`power.rs`) shells out to
/// `caffeinate -i -s`. `ProcessInfo.beginActivity` is a real first-class
/// macOS API for exactly this — no subprocess needed.
/// `.idleSystemSleepDisabled` matches `caffeinate -s`'s own documented
/// behavior: prevents *idle* system sleep, but only while on AC power — a
/// laptop on battery still sleeps normally, no extra logic required to
/// respect that.
@MainActor
final class PowerKeeper {
    static let shared = PowerKeeper()

    private var activity: NSObjectProtocol?

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard activity == nil else { return } // already running
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "CraftPanel: keep servers reachable for scheduled starts"
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    var isEnabled: Bool { activity != nil }
}
