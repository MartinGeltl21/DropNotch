import Foundation

/// UserDefaults keys for all settings.
enum Settings {
    /// Copy files into the shelf when dropping them instead of just linking them.
    static let copyFiles = "copyFiles"
    /// Remove items after they've been dragged out of the shelf and dropped.
    static let removeAfterDragOut = "removeAfterDragOut"
    /// Show the current song (artwork + equalizer) in the closed notch as well.
    static let showMusicWhenClosed = "showMusicWhenClosed"
    /// Global keyboard shortcut ⌃⌥D to open and close the notch.
    static let hotKeyEnabled = "hotKeyEnabled"
    /// Which screen the notch sits on (raw value of `NotchScreenMode`).
    static let notchScreen = "notchScreen"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            copyFiles: false,
            removeAfterDragOut: false,
            showMusicWhenClosed: true,
            hotKeyEnabled: true,
            notchScreen: NotchScreenMode.notchDisplay.rawValue,
        ])
    }
}

/// Which screen the notch sits on when several are connected.
enum NotchScreenMode: String, CaseIterable {
    /// Always on the display with the notch; without one (e.g. lid closed) on the main screen.
    case notchDisplay
    /// The closed notch moves to the screen the mouse is on.
    case mouse

    var title: String {
        switch self {
        case .notchDisplay: return "Display with Notch"
        case .mouse: return "Screen with Mouse Pointer"
        }
    }

    static var current: NotchScreenMode {
        UserDefaults.standard.string(forKey: Settings.notchScreen).flatMap(NotchScreenMode.init) ?? .notchDisplay
    }
}
