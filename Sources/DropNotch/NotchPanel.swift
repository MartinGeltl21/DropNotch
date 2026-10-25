import AppKit
import SwiftUI

/// Rahmenloses, transparentes Panel, das über der Menüleiste an der Notch sitzt.
/// Es aktiviert die App nicht (kein Fokus-Klau) und ist auf allen Spaces sichtbar.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting-View, die schon den ersten Klick annimmt – sonst müsste man eine Datei
/// erst anklicken, bevor man sie aus der Notch ziehen kann.
///
/// Sie ist außerdem das Ablageziel für die ganze Notch. Das läuft über AppKit statt über
/// SwiftUIs `.onDrop`, weil nur so Datei-Versprechen (Mail-Anhänge, Fotos …) ankommen.
/// NSHostingView implementiert die Ziel-Methoden selbst, daher sind sie hier überschrieben.
final class NotchHostingView: NSHostingView<NotchView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(ShelfStore.acceptedDragTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(for: sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(for: sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { rootView.vm.isDropTargeted = false }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        rootView.vm.isDropTargeted = false
        return rootView.shelf.handleDrop(sender.draggingPasteboard)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) { rootView.vm.isDropTargeted = false }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        // Einträge, die gerade aus der Ablage herausgezogen werden, nicht wieder annehmen.
        let accepted = !(sender.draggingSource is ShelfDragSourceView)
        if rootView.vm.isDropTargeted != accepted { rootView.vm.isDropTargeted = accepted }
        return accepted ? .copy : []
    }
}
