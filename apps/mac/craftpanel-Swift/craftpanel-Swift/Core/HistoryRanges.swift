import Foundation

/// Shared 24h/7d/30d presets for the player-activity and metrics-history
/// charts — same ranges, so picking one on one chart reads consistently
/// against the other. Direct port of `historyRanges.ts`.
enum HistoryRange: String, CaseIterable, Identifiable {
    case h24 = "24h", d7 = "7d", d30 = "30d"
    var id: String { rawValue }
    var label: String { rawValue }

    var spanSecs: Int64 {
        switch self {
        case .h24: 24 * 3600
        case .d7: 7 * 86400
        case .d30: 30 * 86400
        }
    }

    /// Chosen per range so each chart draws a sane number of points
    /// (~24-30), not one point per raw sample.
    var bucketSecs: Int64 {
        switch self {
        case .h24: 3600
        case .d7: 6 * 3600
        case .d30: 86400
        }
    }
}
