import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var vm: NotchViewModel
    @State private var selection = Set<UUID>()
    /// Zuletzt angeklickter Eintrag – Ausgangspunkt für ⇧-Klicks.
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
                    Text("Dateien hier reinziehen")
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
        // Klick auf eine freie Stelle hebt die Auswahl auf.
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

    /// Klick wählt nur diesen Eintrag (bzw. hebt ihn wieder auf), ⌘-Klick nimmt ihn hinzu
    /// oder heraus, ⇧-Klick wählt alles bis zum zuletzt angeklickten Eintrag.
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

    /// Ein ausgewählter Eintrag nimmt die ganze Auswahl mit, ein anderer nur sich selbst.
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
            // Klicks und Drags übernimmt AppKit, Hover und Kontextmenü bleiben bei SwiftUI.
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
                .help("Aus Ablage entfernen")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Öffnen") { NSWorkspace.shared.open(item.url) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Per AirDrop senden") {
                NSApp.activate(ignoringOtherApps: true)
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [item.url])
            }
            Divider()
            Button("Aus Ablage entfernen", role: .destructive) { shelf.remove(item) }
        }
        .help(item.url.path)
    }

    private var background: Color {
        if isSelected { return .accentColor.opacity(0.45) }
        return .white.opacity(hovering ? 0.12 : 0)
    }
}

/// Platzhalter, solange eine Datei noch kopiert oder empfangen wird.
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
        .help("Wird abgelegt …")
    }
}

/// Dateiname unter dem Vorschaubild.
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

/// Griff in der Ecke der Ablage, mit dem man alle Einträge auf einmal herauszieht.
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
            .help("Alle Dateien herausziehen")
    }
}

/// Bereits erzeugte Vorschaubilder – damit auch die Drag-Bilder sie zeigen.
enum Thumbnails {
    static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage {
        cache.object(forKey: url as NSURL) ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Zeigt ein QuickLook-Vorschaubild (Bilder, PDFs …) oder sonst das Finder-Icon.
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
