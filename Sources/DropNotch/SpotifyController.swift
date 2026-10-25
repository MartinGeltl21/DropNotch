import AppKit

/// Liest und steuert Spotify über AppleScript.
///
/// Spotify sendet bei jeder Änderung (Play/Pause, neuer Song) die Distributed Notification
/// `com.spotify.client.PlaybackStateChanged`; daraufhin wird der Zustand neu abgefragt.
/// Die Position wird zwischen den Abfragen lokal hochgerechnet.
@MainActor
final class SpotifyController: ObservableObject {
    struct Track: Equatable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var artworkURL: URL?
        var duration: Double
    }

    nonisolated static let bundleID = "com.spotify.client"

    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var permissionDenied = false
    @Published private(set) var position: Double = 0
    @Published private(set) var positionDate = Date()

    private let queue = DispatchQueue(label: "de.moritz.dropnotch.applescript")
    private var artworkURL: URL?
    private var observers: [NSObjectProtocol] = []

    init() {
        isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleID else { return }
                MainActor.assumeIsolated {
                    self?.isInstalled = true
                    self?.refresh()
                }
            })
        }

        refresh()
    }

    private var spotifyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func currentPosition(at date: Date) -> Double {
        guard let track else { return 0 }
        let value = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(value, 0), track.duration)
    }

    // MARK: - Zustand abfragen

    func refresh() {
        // Wichtig: Nie ein Skript an Spotify schicken, wenn es nicht läuft –
        // sonst würde macOS Spotify dafür starten.
        guard spotifyIsRunning else {
            isRunning = false
            isPlaying = false
            track = nil
            artwork = nil
            artworkURL = nil
            return
        }
        isRunning = true

        let script = """
        tell application id "\(Self.bundleID)"
            set out to (player state as string)
            try
                set t to current track
                set out to out & linefeed & (id of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (artwork url of t) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string)
            end try
            return out
        end tell
        """
        run(script) { [weak self] result in
            self?.apply(result)
        }
    }

    private func apply(_ result: Result<String, ScriptError>) {
        switch result {
        case .failure(let error):
            permissionDenied = error.code == -1743
            if error.code == -600 { isRunning = false }
        case .success(let output):
            permissionDenied = false
            let parts = output.components(separatedBy: "\n")
            isPlaying = parts.first == "playing"
            guard parts.count >= 8 else {
                track = nil
                return
            }
            var artwork = parts[5]
            // Spotify liefert manchmal http-URLs, die ATS blockiert.
            if artwork.hasPrefix("http://") { artwork = "https://" + artwork.dropFirst(7) }
            let newTrack = Track(
                id: parts[1],
                title: parts[2],
                artist: parts[3],
                album: parts[4],
                artworkURL: URL(string: artwork),
                duration: (Double(parts[6]) ?? 0) / 1000
            )
            if track != newTrack { track = newTrack }
            position = Self.parseNumber(parts[7])
            positionDate = Date()
            loadArtwork(newTrack.artworkURL)
        }
    }

    /// AppleScript formatiert Kommazahlen je nach Systemsprache mit "," statt ".".
    private static func parseNumber(_ string: String) -> Double {
        Double(string.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        guard let url else {
            artwork = nil
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data),
                  self.artworkURL == url else { return }
            self.artwork = image
        }
    }

    // MARK: - Steuerung

    func playPause() {
        guard spotifyIsRunning else {
            openSpotify()
            return
        }
        // Sofort umschalten, damit sich der Button direkt anfühlt.
        position = currentPosition(at: Date())
        positionDate = Date()
        isPlaying.toggle()
        command("playpause")
    }

    func nextTrack() { command("next track") }
    func previousTrack() { command("previous track") }

    func seek(toFraction fraction: Double) {
        guard let track else { return }
        let seconds = track.duration * min(max(fraction, 0), 1)
        position = seconds
        positionDate = Date()
        command("set player position to \(String(format: "%.2f", seconds))")
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func command(_ command: String) {
        guard spotifyIsRunning else { return }
        run("tell application id \"\(Self.bundleID)\" to \(command)") { [weak self] result in
            if case .failure(let error) = result, error.code == -1743 {
                self?.permissionDenied = true
            }
            // Spotify schickt meist selbst eine Notification, aber nicht bei jedem Befehl.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        }
    }

    // MARK: - AppleScript

    struct ScriptError: Error {
        let code: Int
        let message: String
    }

    /// Führt AppleScript auf einer seriellen Queue aus, damit die UI nicht hängt
    /// (z. B. während macOS beim ersten Mal nach der Automation-Erlaubnis fragt).
    private func run(_ source: String, completion: @escaping @MainActor (Result<String, ScriptError>) -> Void) {
        queue.async {
            var errorInfo: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            let result: Result<String, ScriptError>
            if let errorInfo {
                let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
                result = .failure(ScriptError(code: code, message: message))
            } else {
                result = .success(output?.stringValue ?? "")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }
}
