import AppKit
import Carbon.HIToolbox
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
/// Menüleiste durchgehen. Mausbewegungen kommen über globale und lokale Event-Monitore
/// (für Mausereignisse ist keine Bedienungshilfen-Freigabe nötig). Ein Timer fragt die
/// Mausposition nur ab, solange es nötig ist: während Hover- und Schließ-Verzögerung, bei
/// offener Notch und solange die Maustaste gedrückt ist – während eines Drags liefern
/// globale Monitore nicht zuverlässig Ereignisse. Ruht die Maus fern der Notch, läuft nichts.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .closed
    @Published var isDropTargeted = false
    @Published var isPinned = false {
        didSet {
            // Wer über den Pin-Button anheftet, will die Notch wirklich offen halten.
            closesOnOutsideClick = false
            updatePolling()
        }
    }
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
    private weak var music: MusicController?
    private var screen: NSScreen?
    private var timer: Timer?
    private var eventMonitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isButtonDown = false
    private var isFileDragActive = false
    /// Per Tastenkürzel/Menü geöffnet: Ein Klick außerhalb schließt die Notch wieder.
    private var closesOnOutsideClick = false
    private var hoverStart: Date?
    private var leaveStart: Date?

    private let hoverDelay: TimeInterval = 0.08
    private let closeDelay: TimeInterval = 0.25
    private let panelPadding: CGFloat = 40

    var onOpen: (() -> Void)?

    func attach(panel: NSPanel, music: MusicController) {
        self.panel = panel
        self.music = music
        // Geschlossene Breite hängt von der Musik ab → neu zeichnen, wenn sich die Wiedergabe ändert.
        music.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateScreen()
        startTracking()
    }

    // MARK: - Geometrie

    var showsLiveActivity: Bool {
        guard hasPhysicalNotch,
              UserDefaults.standard.bool(forKey: Settings.showMusicWhenClosed),
              let music else { return false }
        return music.isPlaying && music.track != nil
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
        guard let target = targetScreen() else { return }
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

    /// Bildschirm, auf dem die Notch laut Einstellung sitzen soll.
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        switch NotchScreenMode.current {
        case .notchDisplay:
            // Ohne Notch-Display (z. B. zugeklappt) auf den Hauptbildschirm ausweichen.
            return screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first
        case .mouse:
            // Offen bleibt die Notch, wo sie ist – sie wandert nur geschlossen mit.
            if state == .open, let screen,
               let current = screens.first(where: { $0.displayID == screen.displayID }) {
                return current
            }
            let mouse = NSEvent.mouseLocation
            return screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? screens.first
        }
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
        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown]
        eventMonitors = [
            // Ereignisse in anderen Apps …
            NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouse(event) }
            },
            // … und in eigenen Fenstern (Panel, Menüleisten-Icon).
            NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouse(event) }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
                return handled ? nil : event
            },
        ].compactMap { $0 }
    }

    private func handleMouse(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           state == .open, closesOnOutsideClick, !openZone.contains(NSEvent.mouseLocation) {
            close()
        }
        update()
    }

    /// Esc schließt die Notch, sobald das Panel den Tastaturfokus hat.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard Int(event.keyCode) == kVK_Escape, event.window === panel, state == .open else { return false }
        close()
        return true
    }

    /// Hover-Zone etwas großzügiger als die Notch, damit man sie leicht trifft.
    /// Im Peek-Zustand zählt die ganze sichtbare "Hier ablegen"-Fläche, sonst
    /// würde eine Datei, die man direkt auf den Text zieht, nicht angenommen.
    private var hotZone: CGRect {
        let hotSize = state == .peek ? shapeSize : CGSize(width: closedWidth, height: notchSize.height)
        return screenRect(width: hotSize.width + earRadius * 2 + 16, height: hotSize.height + 4)
            .insetBy(dx: 0, dy: -4)
    }

    private var openZone: CGRect {
        screenRect(width: openWidth + earRadius * 2 + 12, height: openHeight + 10)
            .insetBy(dx: 0, dy: -4)
    }

    private func update() {
        if NotchScreenMode.current == .mouse, state != .open,
           targetScreen()?.displayID != screen?.displayID {
            updateScreen()
        }

        let mouse = NSEvent.mouseLocation
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        updateDragState(buttonDown: buttonDown)

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
        updatePolling()
    }

    /// Erkennt, ob gerade systemweit eine Datei gezogen wird: Beim Start eines Drags
    /// ändert sich der changeCount des Drag-Pasteboards.
    private func updateDragState(buttonDown: Bool) {
        if buttonDown {
            let pasteboard = NSPasteboard(name: .drag)
            if pasteboard.changeCount != lastDragChangeCount {
                lastDragChangeCount = pasteboard.changeCount
                let types = pasteboard.types ?? []
                isFileDragActive = types.contains(.fileURL) || types.contains(.tiff) || types.contains(.png)
            }
        } else {
            // Nur beim Loslassen abgleichen – im Leerlauf wird das Pasteboard nicht abgefragt.
            if isButtonDown { lastDragChangeCount = NSPasteboard(name: .drag).changeCount }
            isFileDragActive = false
            isInternalDragActive = false
        }
        isButtonDown = buttonDown
    }

    /// Ob sich gerade etwas ohne Mausereignis ändern kann (abgelaufene Verzögerung,
    /// Drag ohne globale Ereignisse, Verlassen des offenen Panels) – dann wird abgefragt.
    private var needsPolling: Bool {
        isButtonDown || hoverStart != nil || leaveStart != nil
            || state == .peek || (state == .open && !isPinned)
    }

    private func updatePolling() {
        if !needsPolling {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
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

    /// Öffnet die Notch per Tastenkürzel oder Menü: angeheftet und mit Tastaturfokus, damit
    /// Esc sie schließt. Das Panel aktiviert die App nicht, die vorderste App bleibt aktiv.
    /// Ein Klick außerhalb schließt sie wieder, außer sie war schon über den Pin-Button angeheftet.
    func openPinned() {
        if !isPinned {
            isPinned = true
            closesOnOutsideClick = true
        }
        open()
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Für das Tastenkürzel: auf- bzw. zuklappen.
    func toggle() {
        if state == .open { close() } else { openPinned() }
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
        if newState != .open {
            leaveStart = nil
            returnKeyboardFocus()
        }
        updatePolling()
    }

    /// Gibt den Tastaturfokus an die vorderste App zurück, falls das Panel ihn hatte
    /// (nach Tastenkürzel, Menü oder einem Klick in die Notch). `orderFrontRegardless`
    /// macht das Panel dabei nicht wieder zum Key-Window.
    private func returnKeyboardFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}

@MainActor
private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
