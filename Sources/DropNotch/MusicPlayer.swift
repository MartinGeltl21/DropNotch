import AppKit
import SwiftUI

/// A music player that can be controlled via AppleScript, and everything in which the players differ.
struct MusicPlayer: Identifiable, Equatable {
    /// Where the artwork comes from.
    enum Artwork: Equatable {
        /// AppleScript expression for the artwork URL of track `t`; queried together with the state.
        case url(String)
        /// AppleScript expression for the image data of the current track; queried once per track.
        case data(String)
    }

    let bundleID: String
    let name: String
    /// Distributed notification the player posts on every change (play/pause, new song).
    let notification: Notification.Name
    /// The reported track duration divided by this gives seconds (Spotify reports milliseconds).
    let durationDivisor: Double
    let artwork: Artwork
    /// Color for the equalizer and buttons.
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
        name: "Music",
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

    /// Queries state, volume and the current track, one value per line.
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
