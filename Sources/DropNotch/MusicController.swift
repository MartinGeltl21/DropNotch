import AppKit

/// Reads and controls Spotify and Apple Music via AppleScript.
///
/// Both players post a distributed notification on every change (play/pause, new song);
/// the state is then queried again. Between queries the position is extrapolated
/// locally. The player that is currently playing is controlled (if both are, the one
/// started most recently), otherwise the last controlled one, as long as it is running.
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

    /// Last known state of a running player.
    private struct PlayerState: Equatable {
        var isPlaying = false
        /// Last switch between play and pause – decides which one is active when both are playing.
        var changedAt = Date.distantPast
        /// The player reported "Stopped" (happens when quitting). It isn't queried until the
        /// next notification – otherwise macOS would relaunch it right away.
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
    /// The controlled player; `nil` if none is running.
    @Published private(set) var player: MusicPlayer?
    @Published private(set) var artwork: NSImage?
    /// Only running players have an entry.
    @Published private var states: [MusicPlayer.ID: PlayerState] = [:]

    private let queue = DispatchQueue(label: "de.moritz.dropnotch.applescript")
    private var artworkKey: String?
    /// Players with a state query in flight. If the queue hangs (e.g. on the macOS
    /// permission prompt), this keeps further queries from piling up.
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
                        // Freshly launched: a "Stopped" from the last quit no longer applies.
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

    // MARK: - Querying state

    func refresh() {
        // Important: never send a script to a player that isn't running –
        // macOS would launch it to handle the script.
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

    /// Re-queries the state every second while the open notch shows the player –
    /// this also catches seeking in the player itself, which posts no notification.
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
            // The players report "Stopped" when quitting. If we queried them via AppleScript
            // then, macOS would relaunch the player right away.
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
                // Player is no longer running.
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
            // Don't overwrite with older values while the volume slider is being dragged.
            if parts.count > 1, !isVolumeThrottled { state.volume = Self.parseNumber(parts[1]) }
            if parts.count >= 9 {
                var artwork = parts[6]
                // Spotify sometimes returns http URLs, which ATS blocks.
                if artwork.hasPrefix("http://") { artwork = "https://" + artwork.dropFirst(7) }
                let track = Track(
                    id: parts[2],
                    title: parts[3],
                    artist: parts[4],
                    album: parts[5],
                    artworkURL: URL(string: artwork),
                    duration: Self.parseNumber(parts[7]) / player.durationDivisor
                )
                // Only reset the position if it noticeably deviates from the extrapolation
                // (e.g. after seeking in the player) – otherwise every query would redraw.
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

    /// Picks the controlled player: the one playing (if several, the one started most recently),
    /// otherwise the previous one as long as it is running, otherwise any running one.
    private func updateActivePlayer() {
        let candidates = MusicPlayer.all.compactMap { player in states[player.id].map { (player, $0) } }
        let playing = candidates.filter { $0.1.isPlaying }.max { $0.1.changedAt < $1.1.changedAt }?.0
        let previous = candidates.first { $0.0 == player }?.0
        let next = playing ?? previous ?? candidates.first?.0
        if next != player { player = next }
        loadArtwork()
    }

    /// Depending on the system language, AppleScript formats decimals with "," instead of ".".
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
            // Music returns the image data as PICT, JPEG or PNG depending on the track;
            // NSImage detects the format itself. Without artwork the script fails.
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

    // MARK: - Controls

    func playPause() {
        guard let player, var state = states[player.id] else { return }
        // Toggle immediately so the button feels responsive.
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

    /// Sends at most one volume command every 0.15 s so dragging the slider doesn't
    /// flood the player with AppleScript. The last value is always sent.
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
            // The players usually post a notification themselves, but not for every command.
            if refreshAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
            }
        }
    }

    // MARK: - AppleScript

    struct ScriptOutput {
        let text: String
        /// Raw data of the result, e.g. the image data of an album cover.
        let data: Data
    }

    struct ScriptError: Error {
        let code: Int
        let message: String
    }

    /// Runs AppleScript on a serial queue so the UI doesn't hang
    /// (e.g. while macOS asks for Automation permission the first time).
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
