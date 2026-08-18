import Foundation

/// These app-only presentation choices belong in `UserDefaults`.
/// `~/.wakawaka/settings.json` is a cross-process hook contract, so adding HUD
/// state there would couple local UI preferences to the hook schema.
struct FloatingPanelPreferences {
    private enum Key {
        static let isEnabled = "floatingPanel.enabled"
        static let mode = "floatingPanel.mode"
        static let isPinned = "floatingPanel.pinned"
        static let opacity = "floatingPanel.opacity"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Key.isEnabled) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.isEnabled) }
    }

    var mode: FloatingPanelMode {
        get {
            guard let rawValue = defaults.string(forKey: Key.mode) else {
                return .compact
            }
            return FloatingPanelMode(rawValue: rawValue) ?? .compact
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    var isPinned: Bool {
        get { defaults.object(forKey: Key.isPinned) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.isPinned) }
    }

    /// Persisted defaults can outlive code versions or be edited externally, so
    /// reads reject non-finite values and clamp the range before AppKit receives
    /// an unusable alpha value.
    var opacity: Double {
        get {
            guard defaults.object(forKey: Key.opacity) != nil else {
                return 0.95
            }
            let storedOpacity = defaults.double(forKey: Key.opacity)
            guard storedOpacity.isFinite else {
                return 0.95
            }
            return min(max(storedOpacity, 0.35), 1.0)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.opacity) }
    }
}
