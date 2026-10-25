import AppKit
import Combine
import SwiftUI

enum NotchState: Equatable {
    /// Unsichtbar bzw. genau so groß wie die echte Notch.
    case closed
    /// Irgendwo auf dem Bildschirm wird eine Datei gezogen – Notch zeigt "Hier ablegen".
    case peek
    /// Maus ist über der Notch – Ablage und Musik sind sichtbar.
    case open
}

/// Hält Zustand und Geometrie der Notch und verfolgt die Maus global.
///
/// Das Panel ignoriert Mausereignisse, solange die Notch zu ist, damit Klicks auf die
/// Menüleiste durchgehen. Ein Timer fragt die Mausposition ab; sobald sie in der Notch
/// landet (auch während eines Drag-Vorgangs), klappt die Notch auf.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .closed
    @Published var isDropTargeted = false
    @Published var isPinned = false
    @Published private(set) var notchSize = CGSize(width: 200, height: 32)
    @Published private(set) var hasPhysicalNotch = false

    /// Breite der "Ohren" (die nach außen gebogenen oberen Ecken der Notch-Form).
    let earRadius: CGFloat = 10
    /// Wie breit Cover/Equalizer links und rechts neben der echten Notch sind.
    var liveActivityWing: CGFloat { notchSize.height + 6 }
    let openWidth: CGFloat = 660
    var openHeight: CGFloat { notchSize.height + 170 }

    /// Wird von der Ablage gesetzt, wenn eine Datei aus der Notch herausgezogen wird.
    var isInternalDragActive = false

    private weak var panel: NSPanel?
    private weak var spotify: SpotifyController?
    private var screen: NSScreen?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isFileDragActive = false
    private var hoverStart: Date?
    private var leaveStart: Date?

    private let hoverDelay: TimeInterval = 0.08
    private let closeDelay: TimeInterval = 0.25
    private let panelPadding: CGFloat = 40

    var onOpen: (() -> Void)?

    func attach(panel: NSPanel, spotify: SpotifyController) {
        self.panel = panel
        self.spotify = spotify
        // Geschlossene Breite hängt von der Musik ab → neu zeichnen, wenn sich Spotify ändert.
        spotify.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateScreen()
        startTracking()
    }

    // MARK: - Geometrie

    var showsLiveActivity: Bool {
        guard hasPhysicalNotch,
              UserDefaults.standard.bool(forKey: Settings.showMusicWhenClosed),
              let spotify else { return false }
        return spotify.isPlaying && spotify.track != nil
    }

    var closedWidth: CGFloat {
        notchSize.width + (showsLiveActivity ? liveActivityWing * 2 : 0)
    }

    /// Größe der schwarzen Form (ohne Ohren) im aktuellen Zustand.
    var shapeSize: CGSize {
        switch state {
        case .closed:
            return CGSize(width: closedWidth, height: notchSize.height)
        case .peek:
            return CGSize(width: max(closedWidth, notchSize.width + 150), height: notchSize.height + 36)
        case .open:
            return CGSize(width: openWidth, height: openHeight)
        }
    }

    func updateScreen() {
        let screens = NSScreen.screens
        let target = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first
        guard let target else { return }
        screen = target

        if target.safeAreaInsets.top > 0 {
            let left = target.auxiliaryTopLeftArea?.width ?? 0
            let right = target.auxiliaryTopRightArea?.width ?? 0
            notchSize = CGSize(width: target.frame.width - left - right, height: target.safeAreaInsets.top)
            hasPhysicalNotch = true
        } else {
            // Kein Notch-Display: unsichtbare Zone mittig in der Menüleiste.
            let menuBar = target.frame.maxY - target.visibleFrame.maxY
            notchSize = CGSize(width: 220, height: max(menuBar, 24))
            hasPhysicalNotch = false
        }

        let size = CGSize(width: openWidth + earRadius * 2 + panelPadding * 2,
                          height: openHeight + panelPadding)
        let frame = CGRect(x: target.frame.midX - size.width / 2,
                           y: target.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel?.setFrame(frame, display: true)
    }

    /// Rechteck in Bildschirmkoordinaten (Ursprung unten links), oben mittig verankert.
    private func screenRect(width: CGFloat, height: CGFloat) -> CGRect {
        guard let screen else { return .zero }
        return CGRect(x: screen.frame.midX - width / 2,
                      y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    // MARK: - Maus-Tracking

    private func startTracking() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        updateDragState(buttonDown: buttonDown)

        // Hover-Zone etwas großzügiger als die Notch, damit man sie leicht trifft.
        // Im Peek-Zustand zählt die ganze sichtbare "Hier ablegen"-Fläche, sonst
        // würde eine Datei, die man direkt auf den Text zieht, nicht angenommen.
        let hotSize = state == .peek ? shapeSize : CGSize(width: closedWidth, height: notchSize.height)
        let hotZone = screenRect(width: hotSize.width + earRadius * 2 + 16, height: hotSize.height + 4)
            .insetBy(dx: 0, dy: -4)
        let openZone = screenRect(width: openWidth + earRadius * 2 + 12, height: openHeight + 10)
            .insetBy(dx: 0, dy: -4)

        switch state {
        case .closed, .peek:
            if hotZone.contains(mouse) {
                if isFileDragActive {
                    open()
                } else if let start = hoverStart {
                    if Date().timeIntervalSince(start) >= hoverDelay { open() }
                } else {
                    hoverStart = Date()
                }
            } else {
                hoverStart = nil
                setState(isFileDragActive ? .peek : .closed)
            }

        case .open:
            if openZone.contains(mouse) || isPinned {
                leaveStart = nil
            } else if buttonDown && isInternalDragActive {
                // Datei wird gerade aus der Ablage gezogen: offen lassen, bis sie losgelassen wird.
                leaveStart = nil
            } else if isFileDragActive {
                setState(.peek)
            } else if let start = leaveStart {
                if Date().timeIntervalSince(start) >= closeDelay { setState(.closed) }
            } else {
                leaveStart = Date()
            }
        }
    }

    /// Erkennt, ob gerade systemweit eine Datei gezogen wird: Beim Start eines Drags
    /// ändert sich der changeCount des Drag-Pasteboards.
    private func updateDragState(buttonDown: Bool) {
        let pasteboard = NSPasteboard(name: .drag)
        if buttonDown {
            if pasteboard.changeCount != lastDragChangeCount {
                lastDragChangeCount = pasteboard.changeCount
                let types = pasteboard.types ?? []
                isFileDragActive = types.contains(.fileURL) || types.contains(.tiff) || types.contains(.png)
            }
        } else {
            isFileDragActive = false
            isInternalDragActive = false
            lastDragChangeCount = pasteboard.changeCount
        }
    }

    func open() {
        guard state != .open else { return }
        hoverStart = nil
        leaveStart = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        setState(.open)
        onOpen?()
    }

    func close() {
        isPinned = false
        setState(.closed)
    }

    private func setState(_ newState: NotchState) {
        guard state != newState else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            state = newState
        }
        panel?.ignoresMouseEvents = newState != .open
        if newState != .open { leaveStart = nil }
    }
}
