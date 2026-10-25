import AppKit
import SwiftUI

/// Ein per AppleScript steuerbarer Musikplayer und alles, worin sich die Player unterscheiden.
struct MusicPlayer: Identifiable, Equatable {
    /// Woher das Cover kommt.
    enum Artwork: Equatable {
        /// AppleScript-Ausdruck für die Cover-URL des Titels `t`; wird mit dem Zustand abgefragt.
        case url(String)
        /// AppleScript-Ausdruck für die Bilddaten des aktuellen Titels; wird einmal pro Titel abgefragt.
        case data(String)
    }

    let bundleID: String
    let name: String
    /// Distributed Notification, die der Player bei jeder Änderung (Play/Pause, neuer Song) schickt.
    let notification: Notification.Name
    /// Die gemeldete Titeldauer geteilt hierdurch ergibt Sekunden (Spotify meldet Millisekunden).
    let durationDivisor: Double
    let artwork: Artwork
    /// Farbe für Equalizer und Buttons.
    let accent: Color

    var id: String { bundleID }

    static let spotify = MusicPlayer(
        bundleID: "com.spotify.client",
        name: "Spotify",
        notification: Notification.Name("com.spotify.client.PlaybackStateChanged"),
        durationDivisor: 1000,
        artwork: .url("artwork url of t"),
        accent: .green
    )

    static let appleMusic = MusicPlayer(
        bundleID: "com.apple.Music",
        name: "Musik",
        notification: Notification.Name("com.apple.Music.playerInfo"),
        durationDivisor: 1,
        artwork: .data("raw data of artwork 1 of current track"),
        accent: Color(red: 0.98, green: 0.24, blue: 0.33)
    )

    static let all = [spotify, appleMusic]

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    var icon: NSImage? { appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    /// Fragt Zustand, Lautstärke und aktuellen Titel zeilenweise ab.
    var stateScript: String {
        let artworkURL: String
        switch artwork {
        case .url(let expression): artworkURL = "(\(expression))"
        case .data: artworkURL = "\"\""
        }
        return """
        tell application id "\(bundleID)"
            set out to (player state as string) & linefeed & (sound volume as string)
            try
                set t to current track
                set out to out & linefeed & (id of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & \(artworkURL) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string)
            end try
            return out
        end tell
        """
    }
}
