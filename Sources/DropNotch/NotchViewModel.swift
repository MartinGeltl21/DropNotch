import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

enum NotchState: Equatable {
    /// Invisible, or exactly the size of the real notch.
    case closed
    /// A file is being dragged somewhere on screen – the notch shows "Drop here".
    case peek
    /// The mouse is over the notch – shelf and music are visible.
    case open
}

/// Holds the notch's state and geometry and tracks the mouse globally.
///
/// The panel ignores mouse events while the notch is closed so clicks on the menu bar
/// pass through. Mouse movements arrive via global and local event monitors
/// (mouse events don't require Accessibility permission). A timer polls the mouse
/// position only while needed: during the hover and close delays, while the notch is
/// open and while the mouse button is held down – during a drag, global monitors don't
/// deliver events reliably. When the mouse rests away from the notch, nothing runs.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .closed
    @Published var isDropTargeted = false
    @Published var isPinned = false {
        didSet {
            // Pinning via the pin button means the user really wants to keep the notch open.
            closesOnOutsideClick = false
            updatePolling()
        }
    }
    @Published private(set) var notchSize = CGSize(width: 200, height: 32)
    @Published private(set) var hasPhysicalNotch = false

    /// Width of the "ears" (the outward-curving top corners of the notch shape).
    let earRadius: CGFloat = 10
    /// How wide the artwork/equalizer are to the left and right of the real notch.
    var liveActivityWing: CGFloat { notchSize.height + 6 }
    let openWidth: CGFloat = 660
    var openHeight: CGFloat { notchSize.height + 170 }

    /// Set by the shelf when a file is dragged out of the notch.
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
    /// Opened via keyboard shortcut/menu: a click outside closes the notch again.
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
        // The closed width depends on the music → redraw when playback changes.
        music.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateScreen()
        startTracking()
    }

    // MARK: - Geometry

    var showsLiveActivity: Bool {
        guard hasPhysicalNotch,
              UserDefaults.standard.bool(forKey: Settings.showMusicWhenClosed),
              let music else { return false }
        return music.isPlaying && music.track != nil
    }

    var closedWidth: CGFloat {
        notchSize.width + (showsLiveActivity ? liveActivityWing * 2 : 0)
    }

    /// Size of the black shape (without ears) in the current state.
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
            // No notch display: invisible zone in the middle of the menu bar.
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

    /// Screen the notch should sit on according to the settings.
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        switch NotchScreenMode.current {
        case .notchDisplay:
            // Without a notch display (e.g. lid closed), fall back to the main screen.
            return screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first
        case .mouse:
            // While open, the notch stays where it is – it only follows the mouse when closed.
            if state == .open, let screen,
               let current = screens.first(where: { $0.displayID == screen.displayID }) {
                return current
            }
            let mouse = NSEvent.mouseLocation
            return screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? screens.first
        }
    }

    /// Rectangle in screen coordinates (origin bottom left), anchored at the top center.
    private func screenRect(width: CGFloat, height: CGFloat) -> CGRect {
        guard let screen else { return .zero }
        return CGRect(x: screen.frame.midX - width / 2,
                      y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    // MARK: - Mouse tracking

    private func startTracking() {
        let mouseEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown]
        eventMonitors = [
            // Events in other apps …
            NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouse(event) }
            },
            // … and in our own windows (panel, menu bar icon).
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

    /// Esc closes the notch once the panel has keyboard focus.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard Int(event.keyCode) == kVK_Escape, event.window === panel, state == .open else { return false }
        close()
        return true
    }

    /// Hover zone slightly larger than the notch so it's easy to hit.
    /// In the peek state the whole visible "Drop here" area counts, otherwise
    /// a file dragged directly onto the text wouldn't be accepted.
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
                // A file is being dragged out of the shelf: stay open until it's released.
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

    /// Detects whether a file is currently being dragged system-wide: when a drag starts,
    /// the changeCount of the drag pasteboard changes.
    private func updateDragState(buttonDown: Bool) {
        if buttonDown {
            let pasteboard = NSPasteboard(name: .drag)
            if pasteboard.changeCount != lastDragChangeCount {
                lastDragChangeCount = pasteboard.changeCount
                let types = pasteboard.types ?? []
                isFileDragActive = types.contains(where: ShelfStore.acceptedDragTypes.contains)
            }
        } else {
            // Only sync on release – the pasteboard isn't queried while idle.
            if isButtonDown { lastDragChangeCount = NSPasteboard(name: .drag).changeCount }
            isFileDragActive = false
            isInternalDragActive = false
        }
        isButtonDown = buttonDown
    }

    /// Whether something can currently change without a mouse event (expired delay,
    /// drag without global events, leaving the open panel) – if so, we poll.
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

    /// Opens the notch via keyboard shortcut or menu: pinned and with keyboard focus so that
    /// Esc closes it. The panel doesn't activate the app; the frontmost app stays active.
    /// A click outside closes it again, unless it was already pinned via the pin button.
    func openPinned() {
        if !isPinned {
            isPinned = true
            closesOnOutsideClick = true
        }
        open()
        panel?.makeKeyAndOrderFront(nil)
    }

    /// For the keyboard shortcut: open or close.
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

    /// Returns keyboard focus to the frontmost app if the panel had it
    /// (after the keyboard shortcut, the menu or a click into the notch). `orderFrontRegardless`
    /// doesn't make the panel the key window again.
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
