import AppKit
import SwiftUI

/// Turns an area of the shelf into a drag source. SwiftUI's `.onDrag` only provides a
/// single provider – here every file gets its own `NSDraggingItem`, so several files
/// can be dragged out at once.
struct ShelfDragSource: NSViewRepresentable {
    let shelf: ShelfStore
    let vm: NotchViewModel
    /// The items that are taken along when the drag starts.
    let items: () -> [ShelfItem]
    /// Click without dragging; the event provides the click count and modifier keys.
    var onClick: (NSEvent) -> Void = { _ in }

    func makeNSView(context: Context) -> ShelfDragSourceView { ShelfDragSourceView(source: self) }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) { view.source = self }
}

final class ShelfDragSourceView: NSView, NSDraggingSource {
    var source: ShelfDragSource
    private var mouseDownEvent: NSEvent?
    private var draggedItems: [ShelfItem] = []

    /// Side length of the preview image under the mouse pointer.
    private static let imageSize: CGFloat = 52
    /// Mouse movement (in points) from which a click becomes a drag.
    private static let dragThreshold: CGFloat = 3

    init(source: ShelfDragSource) {
        self.source = source
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard hypot(dx, dy) >= Self.dragThreshold else { return }
        mouseDownEvent = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        source.onClick(event)
    }

    /// The context menu comes from SwiftUI (`.contextMenu`) – the hosting view above knows it.
    override func menu(for event: NSEvent) -> NSMenu? {
        var view = superview
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
    }

    // MARK: - Drag

    private func beginDrag(with event: NSEvent) {
        let items = source.items()
        guard !items.isEmpty else { return }
        let location = convert(event.locationInWindow, from: nil)
        let size = Self.imageSize
        // Stacked with a slight offset, like in Finder.
        let draggingItems = items.enumerated().map { index, item in
            let offset = CGFloat(min(index, 4)) * 4
            let frame = NSRect(x: location.x - size / 2 + offset, y: location.y - size / 2 - offset,
                               width: size, height: size)
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            draggingItem.setDraggingFrame(frame, contents: Self.dragImage(for: item.url))
            return draggingItem
        }
        draggedItems = items
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// Thumbnail or icon, fitted into a square.
    private static func dragImage(for url: URL) -> NSImage {
        let image = Thumbnails.image(for: url)
        return NSImage(size: NSSize(width: imageSize, height: imageSize), flipped: false) { rect in
            guard image.size.width > 0, image.size.height > 0 else { return false }
            let scale = min(rect.width / image.size.width, rect.height / image.size.height)
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
            return true
        }
    }

    /// Only offer copying: the originals must never be moved by a drag.
    /// (The destination may interpret `.generic` as a move.)
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        source.vm.isInternalDragActive = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // The notch itself doesn't accept its own items; there the drag ends with `.none`.
        source.shelf.dragEnded(draggedItems, operation: operation)
        draggedItems = []
    }
}
