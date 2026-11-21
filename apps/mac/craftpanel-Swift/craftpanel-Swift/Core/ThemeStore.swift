import Foundation
import Observation

/// The active theme, persisted.
@MainActor @Observable
final class ThemeStore {
    static let shared = ThemeStore()
    private static let key = "cp.theme"
    private(set) var theme: CPThemeID

    private init() {
        let saved = CPThemeID(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .dark
        theme = saved
        CPColor.palette = saved.palette
    }

    func set(_ t: CPThemeID) {
        theme = t
        CPColor.palette = t.palette
        UserDefaults.standard.set(t.rawValue, forKey: Self.key)
    }
}
