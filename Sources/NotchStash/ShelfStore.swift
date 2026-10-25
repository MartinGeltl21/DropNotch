import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    var url: URL
    /// Bookmark, damit verlinkte Dateien auch nach Verschieben/Umbenennen gefunden werden.
    var bookmark: Data?
    /// true = Kopie liegt im App-eigenen Ordner und wird beim Entfernen gelöscht.
    var isCopy: Bool

    var name: String { url.lastPathComponent }
}

/// Die Datei-Ablage. Wird als JSON in ~/Library/Application Support/NotchStash gespeichert,
/// überlebt also Neustarts.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    let baseDir: URL
    var filesDir: URL { baseDir.appendingPathComponent("Files", isDirectory: true) }
    private var indexURL: URL { baseDir.appendingPathComponent("shelf.json") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = support.appendingPathComponent("NotchStash", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        load()
    }

    private var copyFiles: Bool { UserDefaults.standard.bool(forKey: Settings.copyFiles) }

    // MARK: - Hinzufügen

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add(fileURL: url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                // z. B. Bilder aus dem Browser, die keine echte Datei sind.
                accepted = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in self.add(image: image) }
                }
            }
        }
        return accepted
    }

    func add(fileURL: URL) {
        let url = fileURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              !items.contains(where: { $0.url.standardizedFileURL == url }) else { return }

        if copyFiles && !url.path.hasPrefix(filesDir.path) {
            let id = UUID()
            let destination = makeItemDir(id).appendingPathComponent(url.lastPathComponent)
            // Große Ordner nicht auf dem Main-Thread kopieren.
            Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    await MainActor.run {
                        self.append(ShelfItem(id: id, url: destination, bookmark: nil, isCopy: true))
                    }
                } catch {
                    NSLog("NotchStash: Kopieren fehlgeschlagen: \(error)")
                }
            }
        } else {
            let bookmark = try? url.bookmarkData()
            append(ShelfItem(id: UUID(), url: url, bookmark: bookmark, isCopy: false))
        }
    }

    func add(image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let id = UUID()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        let url = makeItemDir(id).appendingPathComponent("Bild \(formatter.string(from: Date())).png")
        do {
            try png.write(to: url)
            append(ShelfItem(id: id, url: url, bookmark: nil, isCopy: true))
        } catch {
            NSLog("NotchStash: Bild speichern fehlgeschlagen: \(error)")
        }
    }

    private func makeItemDir(_ id: UUID) -> URL {
        let dir = filesDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func append(_ item: ShelfItem) {
        items.append(item)
        save()
    }

    // MARK: - Entfernen

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        deleteCopyIfNeeded(item)
        save()
    }

    func clear() {
        items.forEach(deleteCopyIfNeeded)
        items.removeAll()
        save()
    }

    private func deleteCopyIfNeeded(_ item: ShelfItem) {
        guard item.isCopy else { return }
        // Nur den App-eigenen Ordner löschen, nie Originaldateien.
        let dir = item.url.deletingLastPathComponent()
        if dir.path.hasPrefix(filesDir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Persistenz

    /// Bookmarks neu auflösen und Einträge entfernen, deren Datei nicht mehr existiert.
    func refresh() {
        var changed = false
        items = items.compactMap { item in
            var item = item
            if let bookmark = item.bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
                   resolved != item.url {
                    item.url = resolved
                    changed = true
                }
                if stale {
                    item.bookmark = try? item.url.bookmarkData()
                    changed = true
                }
            }
            guard FileManager.default.fileExists(atPath: item.url.path) else {
                changed = true
                return nil
            }
            return item
        }
        if changed { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded
        refresh()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("NotchStash: Ablage speichern fehlgeschlagen: \(error)")
        }
    }
}
