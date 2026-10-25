import Foundation

/// UserDefaults-Schlüssel für alle Einstellungen.
enum Settings {
    /// Dateien beim Ablegen in die Ablage kopieren statt nur zu verlinken.
    static let copyFiles = "copyFiles"
    /// Einträge entfernen, nachdem sie aus der Ablage herausgezogen und abgelegt wurden.
    static let removeAfterDragOut = "removeAfterDragOut"
    /// Laufenden Song (Cover + Equalizer) auch in der geschlossenen Notch zeigen.
    static let showMusicWhenClosed = "showMusicWhenClosed"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            copyFiles: false,
            removeAfterDragOut: false,
            showMusicWhenClosed: true,
        ])
    }
}
