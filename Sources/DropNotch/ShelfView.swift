import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var vm: NotchViewModel
    @State private var selection = Set<UUID>()
    /// Last clicked item – starting point for ⇧-clicks.
    @State private var anchor: UUID?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(vm.isDropTargeted ? 0.12 : 0.05))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.white.opacity(vm.isDropTargeted ? 0.8 : 0.18))

            if shelf.items.isEmpty && shelf.pendingItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24))
                    Text("Drag files here")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items) { item in
                            ShelfItemView(item: item, isSelected: selection.contains(item.id), shelf: shelf, vm: vm,
                                          dragItems: { dragItems(for: item) },
                                          onSelect: { select(item, modifiers: $0) })
                        }
                        ForEach(shelf.pendingItems) { PendingItemView(item: $0) }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        // Clicking an empty spot clears the selection.
        .contentShape(Rectangle())
        .onTapGesture { selection.removeAll() }
        .overlay(alignment: .bottomTrailing) {
            if shelf.items.count > 1 {
                DragAllChip(shelf: shelf, vm: vm)
                    .padding(6)
            }
        }
        .animation(.easeOut(duration: 0.15), value: vm.isDropTargeted)
    }

    /// Click selects only this item (or deselects it again), ⌘-click adds or removes it,
    /// ⇧-click selects everything up to the last clicked item.
    private func select(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        let ids = shelf.items.map(\.id)
        if modifiers.contains(.shift), let anchor,
           let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: item.id) {
            selection.formUnion(ids[min(from, to)...max(from, to)])
            return
        }
        if modifiers.contains(.command) {
            selection.formSymmetricDifference([item.id])
        } else {
            selection = selection == [item.id] ? [] : [item.id]
        }
        anchor = item.id
    }

    /// A selected item takes the whole selection along, any other item only itself.
    private func dragItems(for item: ShelfItem) -> [ShelfItem] {
        selection.contains(item.id) ? shelf.items.filter { selection.contains($0.id) } : [item]
    }
}

struct ShelfItemView: View {
    let item: ShelfItem
    let isSelected: Bool
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var vm: NotchViewModel
    let dragItems: () -> [ShelfItem]
    let onSelect: (NSEvent.ModifierFlags) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            FileThumbnail(url: item.url)
                .frame(width: 52, height: 52)
            ItemCaption(name: item.name)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .overlay {
            // AppKit handles clicks and drags; hover and the context menu stay with SwiftUI.
            ShelfDragSource(shelf: shelf, vm: vm, items: dragItems) { event in
                if event.clickCount == 2 {
                    NSWorkspace.shared.open(item.url)
                } else {
                    onSelect(event.modifierFlags)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray)
                }
                .buttonStyle(.plain)
                .help("Remove from Shelf")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Send via AirDrop") {
                NSApp.activate(ignoringOtherApps: true)
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [item.url])
            }
            Divider()
            Button("Remove from Shelf", role: .destructive) { shelf.remove(item) }
        }
        .help(item.url.path)
    }

    private var background: Color {
        if isSelected { return .accentColor.opacity(0.45) }
        return .white.opacity(hovering ? 0.12 : 0)
    }
}

/// Placeholder while a file is still being copied or received.
struct PendingItemView: View {
    let item: PendingItem

    var body: some View {
        VStack(spacing: 4) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 52, height: 52)
            ItemCaption(name: item.name)
        }
        .padding(6)
        .opacity(0.6)
        .help("Adding to Shelf…")
    }
}

/// File name below the thumbnail.
struct ItemCaption: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 10))
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .frame(width: 72, height: 26, alignment: .top)
    }
}

/// Handle in the corner of the shelf for dragging out all items at once.
struct DragAllChip: View {
    @ObservedObject var shelf: ShelfStore
    let vm: NotchViewModel

    var body: some View {
        Label("\(shelf.items.count)", systemImage: "doc.on.doc.fill")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.18)))
            .overlay { ShelfDragSource(shelf: shelf, vm: vm, items: { shelf.items }) }
            .help("Drag out all files")
    }
}

/// Thumbnails generated so far – so the drag images can show them too.
enum Thumbnails {
    static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage {
        cache.object(forKey: url as NSURL) ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Shows a Quick Look thumbnail (images, PDFs …) or otherwise the Finder icon.
struct FileThumbnail: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: thumbnail == nil ? 0 : 6))
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: 104, height: 104), scale: 2,
                    representationTypes: .thumbnail
                )
                thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
                if let thumbnail { Thumbnails.cache.setObject(thumbnail, forKey: url as NSURL) }
            }
    }
}
