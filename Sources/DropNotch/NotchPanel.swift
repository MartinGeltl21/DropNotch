import AppKit
import SwiftUI

/// Borderless, transparent panel that sits above the menu bar at the notch.
/// It doesn't activate the app (no focus stealing) and is visible on all Spaces.
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

/// Hosting view that accepts the very first click – otherwise you'd have to click a file
/// before you could drag it out of the notch.
///
/// It is also the drop target for the whole notch. This goes through AppKit instead of
/// SwiftUI's `.onDrop`, because that's the only way file promises (Mail attachments, Photos …) arrive.
/// NSHostingView implements the destination methods itself, so they are overridden here.
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
        // Don't accept items that are currently being dragged out of the shelf.
        let accepted = !(sender.draggingSource is ShelfDragSourceView)
        if rootView.vm.isDropTargeted != accepted { rootView.vm.isDropTargeted = accepted }
        return accepted ? .copy : []
    }
}
