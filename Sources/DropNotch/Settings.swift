import Foundation

/// UserDefaults-Schlüssel für alle Einstellungen.
enum Settings {
    /// Dateien beim Ablegen in die Ablage kopieren statt nur zu verlinken.
    static let copyFiles = "copyFiles"
    /// Laufenden Song (Cover + Equalizer) auch in der geschlossenen Notch zeigen.
    static let showMusicWhenClosed = "showMusicWhenClosed"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            copyFiles: false,
            showMusicWhenClosed: true,
        ])
    }
}
