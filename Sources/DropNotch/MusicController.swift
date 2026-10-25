import AppKit

/// Liest und steuert Spotify und Apple Music über AppleScript.
///
/// Beide Player senden bei jeder Änderung (Play/Pause, neuer Song) eine Distributed
/// Notification; daraufhin wird der Zustand neu abgefragt. Die Position wird zwischen den
/// Abfragen lokal hochgerechnet. Gesteuert wird der Player, der gerade spielt (bei beiden der
/// zuletzt gestartete), sonst der zuletzt gesteuerte, solange er läuft.
@MainActor
final class MusicController: ObservableObject {
    struct Track: Equatable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var artworkURL: URL?
        var duration: Double
    }

    /// Zuletzt bekannter Zustand eines laufenden Players.
    private struct PlayerState: Equatable {
        var isPlaying = false
        /// Letzter Wechsel zwischen Play und Pause – entscheidet, wer aktiv ist, wenn beide spielen.
        var changedAt = Date.distantPast
        /// Der Player hat "Stopped" gemeldet (passiert beim Beenden). Bis zur nächsten
        /// Meldung wird er nicht abgefragt – sonst startet macOS ihn sofort wieder.
        var isStopped = false
        var track: Track?
        var position: Double = 0
        var positionDate = Date()
        var volume: Double = 0
        var permissionDenied = false

        mutating func setPlaying(_ playing: Bool) {
            guard playing != isPlaying else { return }
            isPlaying = playing
            changedAt = Date()
        }

        func elapsed(at date: Date) -> Double {
            guard let track else { return 0 }
            let value = isPlaying ? position + date.timeIntervalSince(positionDate) : position
            return min(max(value, 0), track.duration)
        }
    }

    @Published private(set) var installedPlayers: [MusicPlayer] = []
    /// Der gesteuerte Player; `nil`, wenn keiner läuft.
    @Published private(set) var player: MusicPlayer?
    @Published private(set) var artwork: NSImage?
    /// Nur laufende Player haben einen Eintrag.
    @Published private var states: [MusicPlayer.ID: PlayerState] = [:]

    private let queue = DispatchQueue(label: "de.moritz.dropnotch.applescript")
    private var artworkKey: String?
    /// Player mit laufender Zustandsabfrage. Hängt die Queue (z. B. an der Erlaubnis-Abfrage
    /// von macOS), stauen sich so keine weiteren Abfragen an.
    private var pendingQueries: Set<MusicPlayer.ID> = []
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var pendingVolume: Double?
    private var isVolumeThrottled = false

    private var current: PlayerState? { player.flatMap { states[$0.id] } }
    var isPlaying: Bool { current?.isPlaying ?? false }
    var track: Track? { current?.track }
    var volume: Double { current?.volume ?? 0 }
    var permissionDenied: Bool { current?.permissionDenied ?? false }

    init() {
        installedPlayers = MusicPlayer.all.filter { $0.appURL != nil }

        for player in MusicPlayer.all {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: player.notification, object: nil, queue: .main
            ) { [weak self] note in
                let stopped = note.userInfo?["Player State"] as? String == "Stopped"
                MainActor.assumeIsolated { self?.playerDidChange(player, stopped: stopped) }
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let player = MusicPlayer.all.first(where: { $0.bundleID == app?.bundleIdentifier }) else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if launched {
                        // Frisch gestartet: ein "Stopped" vom letzten Beenden gilt nicht mehr.
                        self.states[player.id] = nil
                        self.installedPlayers = MusicPlayer.all.filter { $0.appURL != nil }
                    }
                    self.refresh()
                }
            })
        }

        refresh()
    }

    func currentPosition(at date: Date) -> Double {
        current?.elapsed(at: date) ?? 0
    }

    // MARK: - Zustand abfragen

    func refresh() {
        // Wichtig: Nie ein Skript an einen Player schicken, der nicht läuft –
        // sonst würde macOS ihn dafür starten.
        let running = MusicPlayer.all.filter(\.isRunning)
        var next: [MusicPlayer.ID: PlayerState] = [:]
        for player in running { next[player.id] = states[player.id] ?? PlayerState() }
        if next != states { states = next }

        for player in running where states[player.id]?.isStopped == false && !pendingQueries.contains(player.id) {
            pendingQueries.insert(player.id)
            run(player.stateScript) { [weak self] result in
                self?.pendingQueries.remove(player.id)
                self?.apply(result, for: player)
            }
        }
        updateActivePlayer()
    }

    /// Fragt den Zustand jede Sekunde neu ab, solange die offene Notch den Player zeigt –
    /// so fällt auch Spulen direkt im Player auf, für das es keine Notification gibt.
    func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.player == nil {
                    self.stopPolling()
                } else {
                    self.refresh()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func playerDidChange(_ player: MusicPlayer, stopped: Bool) {
        if stopped {
            // Beim Beenden melden die Player "Stopped". Würden wir dann per AppleScript
            // nachfragen, startet macOS den Player sofort wieder.
            if player.isRunning {
                var state = states[player.id] ?? PlayerState()
                state.isStopped = true
                state.setPlaying(false)
                state.track = nil
                states[player.id] = state
            }
        } else {
            states[player.id]?.isStopped = false
        }
        refresh()
    }

    private func apply(_ result: Result<ScriptOutput, ScriptError>, for player: MusicPlayer) {
        guard var state = states[player.id], !state.isStopped else { return }
        switch result {
        case .failure(let error):
            if error.code == -600 {
                // Player läuft nicht mehr.
                states[player.id] = nil
                updateActivePlayer()
                return
            }
            state.permissionDenied = error.code == -1743
        case .success(let output):
            state.permissionDenied = false
            let parts = output.text.components(separatedBy: "\n")
            let wasPlaying = state.isPlaying
            state.setPlaying(parts[0] == "playing")
            // Während am Lautstärkeregler gezogen wird, nicht mit älteren Werten überschreiben.
            if parts.count > 1, !isVolumeThrottled { state.volume = Self.parseNumber(parts[1]) }
            if parts.count >= 9 {
                var artwork = parts[6]
                // Spotify liefert manchmal http-URLs, die ATS blockiert.
                if artwork.hasPrefix("http://") { artwork = "https://" + artwork.dropFirst(7) }
                let track = Track(
                    id: parts[2],
                    title: parts[3],
                    artist: parts[4],
                    album: parts[5],
                    artworkURL: URL(string: artwork),
                    duration: Self.parseNumber(parts[7]) / player.durationDivisor
                )
                // Position nur neu setzen, wenn sie spürbar von der Hochrechnung abweicht
                // (z. B. nach Spulen im Player) – sonst würde jede Abfrage neu zeichnen.
                let position = Self.parseNumber(parts[8])
                let drift = abs(position - state.elapsed(at: Date()))
                if track != state.track || state.isPlaying != wasPlaying || drift > (state.isPlaying ? 1 : 0) {
                    state.track = track
                    state.position = position
                    state.positionDate = Date()
                }
            } else {
                state.track = nil
            }
        }
        if states[player.id] != state { states[player.id] = state }
        updateActivePlayer()
    }

    /// Wählt den gesteuerten Player: den spielenden (bei mehreren den zuletzt gestarteten),
    /// sonst den bisherigen, solange er läuft, sonst irgendeinen laufenden.
    private func updateActivePlayer() {
        let candidates = MusicPlayer.all.compactMap { player in states[player.id].map { (player, $0) } }
        let playing = candidates.filter { $0.1.isPlaying }.max { $0.1.changedAt < $1.1.changedAt }?.0
        let previous = candidates.first { $0.0 == player }?.0
        let next = playing ?? previous ?? candidates.first?.0
        if next != player { player = next }
        loadArtwork()
    }

    /// AppleScript formatiert Kommazahlen je nach Systemsprache mit "," statt ".".
    private static func parseNumber(_ string: String) -> Double {
        Double(string.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func loadArtwork() {
        let key = player.flatMap { player in track.map { "\(player.id)/\($0.id)" } }
        guard key != artworkKey else { return }
        artworkKey = key
        guard let key, let player, let track else {
            artwork = nil
            return
        }
        switch player.artwork {
        case .url:
            guard let url = track.artworkURL else {
                artwork = nil
                return
            }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data),
                      self.artworkKey == key else { return }
                self.artwork = image
            }
        case .data(let expression):
            // Musik liefert die Bilddaten je nach Titel als PICT, JPEG oder PNG;
            // NSImage erkennt das Format selbst. Ohne Cover schlägt das Skript fehl.
            run("tell application id \"\(player.bundleID)\" to get \(expression)") { [weak self] result in
                guard let self, self.artworkKey == key else { return }
                if case .success(let output) = result, let image = NSImage(data: output.data) {
                    self.artwork = image
                } else {
                    self.artwork = nil
                }
            }
        }
    }

    // MARK: - Steuerung

    func playPause() {
        guard let player, var state = states[player.id] else { return }
        // Sofort umschalten, damit sich der Button direkt anfühlt.
        state.position = state.elapsed(at: Date())
        state.positionDate = Date()
        state.setPlaying(!state.isPlaying)
        states[player.id] = state
        command("playpause", to: player)
        updateActivePlayer()
    }

    func nextTrack() {
        if let player { command("next track", to: player) }
    }

    func previousTrack() {
        if let player { command("previous track", to: player) }
    }

    func seek(toFraction fraction: Double) {
        guard let player, let track else { return }
        let seconds = track.duration * min(max(fraction, 0), 1)
        states[player.id]?.position = seconds
        states[player.id]?.positionDate = Date()
        command("set player position to \(String(format: "%.2f", seconds))", to: player)
    }

    func setVolume(_ volume: Double) {
        guard let player else { return }
        states[player.id]?.volume = volume
        pendingVolume = volume
        sendPendingVolume(to: player)
    }

    /// Schickt höchstens alle 0,15 s einen Lautstärkebefehl, damit Ziehen am Regler
    /// den Player nicht mit AppleScript flutet. Der letzte Wert geht immer raus.
    private func sendPendingVolume(to player: MusicPlayer) {
        guard !isVolumeThrottled, let volume = pendingVolume else { return }
        pendingVolume = nil
        isVolumeThrottled = true
        command("set sound volume to \(Int(volume.rounded()))", to: player, refreshAfter: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isVolumeThrottled = false
            self?.sendPendingVolume(to: player)
        }
    }

    func open(_ player: MusicPlayer) {
        guard let url = player.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func command(_ command: String, to player: MusicPlayer, refreshAfter: Bool = true) {
        guard player.isRunning else { return }
        run("tell application id \"\(player.bundleID)\" to \(command)") { [weak self] result in
            if case .failure(let error) = result, error.code == -1743 {
                self?.states[player.id]?.permissionDenied = true
            }
            // Die Player schicken meist selbst eine Notification, aber nicht bei jedem Befehl.
            if refreshAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
            }
        }
    }

    // MARK: - AppleScript

    struct ScriptOutput {
        let text: String
        /// Rohdaten des Ergebnisses, z. B. die Bilddaten eines Covers.
        let data: Data
    }

    struct ScriptError: Error {
        let code: Int
        let message: String
    }

    /// Führt AppleScript auf einer seriellen Queue aus, damit die UI nicht hängt
    /// (z. B. während macOS beim ersten Mal nach der Automation-Erlaubnis fragt).
    private func run(_ source: String, completion: @escaping @MainActor (Result<ScriptOutput, ScriptError>) -> Void) {
        queue.async {
            var errorInfo: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            let result: Result<ScriptOutput, ScriptError>
            if let errorInfo {
                let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
                result = .failure(ScriptError(code: code, message: message))
            } else {
                result = .success(ScriptOutput(text: output?.stringValue ?? "", data: output?.data ?? Data()))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }
}
