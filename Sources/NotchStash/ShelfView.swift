import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(vm.isDropTargeted ? 0.12 : 0.05))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.white.opacity(vm.isDropTargeted ? 0.8 : 0.18))

            if shelf.items.isEmpty {
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
                            ShelfItemView(item: item, shelf: shelf, vm: vm)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: vm.isDropTargeted)
    }
}

struct ShelfItemView: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var vm: NotchViewModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            FileThumbnail(url: item.url)
                .frame(width: 52, height: 52)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 72, height: 26, alignment: .top)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.12 : 0)))
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onDrag {
            vm.isInternalDragActive = true
            let provider = NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
            provider.suggestedName = item.name
            return provider
        }
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
            }
    }
}
