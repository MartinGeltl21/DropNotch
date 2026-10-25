import AppKit
import SwiftUI

/// Macht einen Bereich der Ablage zur Drag-Quelle. SwiftUIs `.onDrag` liefert nur einen
/// einzigen Provider – hier bekommt jede Datei ein eigenes `NSDraggingItem`, so lassen sich
/// mehrere Dateien auf einmal herausziehen.
struct ShelfDragSource: NSViewRepresentable {
    let shelf: ShelfStore
    let vm: NotchViewModel
    /// Die Einträge, die beim Drag-Start mitgenommen werden.
    let items: () -> [ShelfItem]
    /// Klick ohne Ziehen; das Ereignis liefert Klickanzahl und Modifier-Tasten.
    var onClick: (NSEvent) -> Void = { _ in }

    func makeNSView(context: Context) -> ShelfDragSourceView { ShelfDragSourceView(source: self) }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) { view.source = self }
}

final class ShelfDragSourceView: NSView, NSDraggingSource {
    var source: ShelfDragSource
    private var mouseDownEvent: NSEvent?
    private var draggedItems: [ShelfItem] = []

    /// Kantenlänge des Vorschaubilds unter dem Mauszeiger.
    private static let imageSize: CGFloat = 52
    /// Ab dieser Mausbewegung (in Punkten) wird aus einem Klick ein Drag.
    private static let dragThreshold: CGFloat = 3

    init(source: ShelfDragSource) {
        self.source = source
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Maus

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

    /// Das Kontextmenü stammt aus SwiftUI (`.contextMenu`) – die Hosting-View darüber kennt es.
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
        // Leicht versetzt gestapelt, wie im Finder.
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

    /// Vorschaubild bzw. Icon, quadratisch eingepasst.
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

    /// Nur Kopieren anbieten: Die Originale dürfen durch einen Drag nie verschoben werden.
    /// (`.generic` dürfte das Ziel als Verschieben auslegen.)
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        source.vm.isInternalDragActive = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Die Notch selbst nimmt eigene Einträge nicht an, dort endet der Drag mit `.none`.
        source.shelf.dragEnded(draggedItems, operation: operation)
        draggedItems = []
    }
}
