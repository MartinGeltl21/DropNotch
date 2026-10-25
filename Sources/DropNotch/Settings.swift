import Foundation

/// UserDefaults-Schlüssel für alle Einstellungen.
enum Settings {
    /// Dateien beim Ablegen in die Ablage kopieren statt nur zu verlinken.
    static let copyFiles = "copyFiles"
    /// Laufenden Song (Cover + Equalizer) auch in der geschlossenen Notch zeigen.
    static let showMusicWhenClosed = "showMusicWhenClosed"
    /// Globales Tastenkürzel ⌃⌥D zum Auf- und Zuklappen der Notch.
    static let hotKeyEnabled = "hotKeyEnabled"
    /// Auf welchem Bildschirm die Notch sitzt (Rohwert von `NotchScreenMode`).
    static let notchScreen = "notchScreen"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            copyFiles: false,
            showMusicWhenClosed: true,
            hotKeyEnabled: true,
            notchScreen: NotchScreenMode.notchDisplay.rawValue,
        ])
    }
}

/// Auf welchem Bildschirm die Notch sitzt, wenn mehrere angeschlossen sind.
enum NotchScreenMode: String, CaseIterable {
    /// Immer auf dem Display mit Notch; ohne eines (z. B. zugeklappt) auf dem Hauptbildschirm.
    case notchDisplay
    /// Die geschlossene Notch wandert auf den Bildschirm, auf dem die Maus ist.
    case mouse

    var title: String {
        switch self {
        case .notchDisplay: return "Display mit Notch"
        case .mouse: return "Bildschirm mit der Maus"
        }
    }

    static var current: NotchScreenMode {
        UserDefaults.standard.string(forKey: Settings.notchScreen).flatMap(NotchScreenMode.init) ?? .notchDisplay
    }
}
