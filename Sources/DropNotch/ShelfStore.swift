import AppKit

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    var url: URL
    /// Bookmark, damit verlinkte Dateien auch nach Verschieben/Umbenennen gefunden werden.
    var bookmark: Data?
    /// true = Kopie liegt im App-eigenen Ordner und wandert beim Entfernen in den Papierkorb.
    var isCopy: Bool
    /// Originaldatei einer Kopie – damit dieselbe Datei nicht doppelt abgelegt wird.
    var sourceURL: URL? = nil

    var name: String { url.lastPathComponent }
}

/// Platzhalter in der Ablage, solange eine Datei noch kopiert oder empfangen wird.
struct PendingItem: Identifiable {
    let id = UUID()
    let name: String
    /// Original, das gerade kopiert wird – nil bei Datei-Versprechen.
    var sourceURL: URL? = nil
    /// Wie viele Dateien noch ausstehen (ein Datei-Versprechen kann mehrere liefern).
    var outstanding = 1
}

/// Die Datei-Ablage. Wird als JSON in ~/Library/Application Support/DropNotch gespeichert,
/// überlebt also Neustarts.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var pendingItems: [PendingItem] = []

    let baseDir: URL
    var filesDir: URL { baseDir.appendingPathComponent("Files", isDirectory: true) }
    private var indexURL: URL { baseDir.appendingPathComponent("shelf.json") }

    private let defaults: UserDefaults
    private let moveToTrash: (URL) throws -> Void
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Ordner, Einstellungen und Papierkorb lassen sich für Tests austauschen.
    init(
        baseDir: URL? = nil,
        defaults: UserDefaults = .standard,
        moveToTrash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.baseDir = baseDir ?? support.appendingPathComponent("DropNotch", isDirectory: true)
        self.defaults = defaults
        self.moveToTrash = moveToTrash
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        load()
    }

    private var copyFiles: Bool { defaults.bool(forKey: Settings.copyFiles) }

    // MARK: - Drag & Drop

    private static let imageTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
    /// Seitentitel, den Safari beim Ziehen eines Links mitliefert.
    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    /// Alles, was die Ablage per Drag & Drop annimmt.
    static var acceptedDragTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            + [.fileURL, .URL, .string] + imageTypes
    }

    /// Übernimmt einen Drop. Vorrang: Datei > Datei-Versprechen > Bild > Web-Link > Text.
    func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            urls.forEach(add(fileURL:))
        } else if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
                  !receivers.isEmpty {
            // z. B. Mail-Anhänge oder Fotos, die erst beim Ablegen geschrieben werden.
            receive(receivers)
        } else if let type = pasteboard.availableType(from: Self.imageTypes),
                  let data = pasteboard.data(forType: type),
                  let image = NSImage(data: data) {
            // z. B. Bilder aus dem Browser, die keine echte Datei sind.
            add(image: image)
        } else if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?
                    .first(where: { ["http", "https"].contains($0.scheme?.lowercased()) }) {
            add(webURL: url, title: pasteboard.string(forType: Self.urlNameType))
        } else if let text = pasteboard.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(text: text)
        } else {
            return false
        }
        return true
    }

    /// Nach dem Herausziehen aus der Ablage: Einträge entfernen, falls so eingestellt und
    /// die Dateien tatsächlich irgendwo abgelegt wurden.
    func dragEnded(_ dragged: [ShelfItem], operation: NSDragOperation) {
        guard operation != [], defaults.bool(forKey: Settings.removeAfterDragOut) else { return }
        let ids = Set(dragged.map(\.id))
        items.removeAll { ids.contains($0.id) }
        save()
        // Das Ziel liest die Datei womöglich erst nach dem Drop (der Finder kopiert z. B.
        // asynchron) – Kopien daher erst etwas später in den Papierkorb legen.
        Task {
            try? await Task.sleep(for: .seconds(10))
            dragged.forEach(deleteCopyIfNeeded)
        }
    }

    // MARK: - Hinzufügen

    func add(fileURL: URL) {
        let url = fileURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              !pendingItems.contains(where: { $0.sourceURL == url }),
              !items.contains(where: { $0.url.standardizedFileURL == url || $0.sourceURL == url })
        else { return }

        if copyFiles && !url.path.hasPrefix(filesDir.path) {
            let pending = PendingItem(name: url.lastPathComponent, sourceURL: url)
            pendingItems.append(pending)
            let dir = makeItemDir(pending.id)
            let destination = dir.appendingPathComponent(url.lastPathComponent)
            // Große Ordner nicht auf dem Main-Thread kopieren.
            Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    let item = ShelfItem(id: pending.id, url: destination, bookmark: nil, isCopy: true, sourceURL: url)
                    await self.finish(pending.id, adding: item)
                } catch {
                    NSLog("DropNotch: Kopieren fehlgeschlagen: \(error)")
                    try? FileManager.default.removeItem(at: dir)
                    await self.finish(pending.id, adding: nil)
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
        write(png, named: "Bild \(Self.timestamp()).png")
    }

    /// Speichert einen Link als .webloc, benannt nach Seitentitel oder Host.
    func add(webURL: URL, title: String? = nil) {
        let name = [title, webURL.host()]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Link"
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["URL": webURL.absoluteString], format: .xml, options: 0
        ) else { return }
        write(data, named: Self.fileName(from: name) + ".webloc")
    }

    func add(text: String) {
        write(Data(text.utf8), named: "Text \(Self.timestamp()).txt")
    }

    /// Nimmt Datei-Versprechen an. Bis die Dateien geschrieben sind, steht ein Platzhalter
    /// in der Ablage.
    private func receive(_ receivers: [NSFilePromiseReceiver]) {
        for receiver in receivers {
            let pending = PendingItem(name: receiver.fileNames.first ?? "Datei",
                                      outstanding: max(receiver.fileNames.count, 1))
            pendingItems.append(pending)
            let staging = makeItemDir(pending.id)
            receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: promiseQueue) { url, error in
                Task { @MainActor in
                    self.receivedPromisedFile(url, error: error, pendingID: pending.id, staging: staging)
                }
            }
        }
    }

    private func receivedPromisedFile(_ url: URL, error: Error?, pendingID: UUID, staging: URL) {
        if let error {
            NSLog("DropNotch: Datei empfangen fehlgeschlagen: \(error)")
        } else {
            // Jede Datei bekommt einen eigenen Ordner, damit sie sich einzeln entfernen lässt.
            let id = UUID()
            let dir = makeItemDir(id)
            let destination = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                append(ShelfItem(id: id, url: destination, bookmark: nil, isCopy: true))
            } catch {
                NSLog("DropNotch: Empfangene Datei verschieben fehlgeschlagen: \(error)")
                try? FileManager.default.removeItem(at: dir)
            }
        }
        guard let index = pendingItems.firstIndex(where: { $0.id == pendingID }) else { return }
        pendingItems[index].outstanding -= 1
        if pendingItems[index].outstanding == 0 {
            pendingItems.remove(at: index)
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// Ersetzt einen Platzhalter durch den fertigen Eintrag (nil = fehlgeschlagen).
    private func finish(_ pendingID: UUID, adding item: ShelfItem?) {
        pendingItems.removeAll { $0.id == pendingID }
        if let item { append(item) }
    }

    /// Legt Daten als neue Datei im App-eigenen Ordner ab.
    private func write(_ data: Data, named name: String) {
        let id = UUID()
        let dir = makeItemDir(id)
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            append(ShelfItem(id: id, url: url, bookmark: nil, isCopy: true))
        } catch {
            NSLog("DropNotch: \(name) speichern fehlgeschlagen: \(error)")
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return formatter
    }()

    private static func timestamp() -> String { timestampFormatter.string(from: Date()) }

    /// Macht aus einem Seitentitel einen gültigen Dateinamen.
    private static func fileName(from title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.newlines))
        return cleaned.isEmpty ? "Link" : String(cleaned.prefix(100))
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
        // Nur Kopien aus dem App-eigenen Ordner, nie Originaldateien. Sie landen im
        // Papierkorb statt endgültig gelöscht zu werden – falls es die einzige Kopie war.
        let dir = item.url.deletingLastPathComponent()
        guard dir.path.hasPrefix(filesDir.path) else { return }
        try? moveToTrash(item.url)
        try? FileManager.default.removeItem(at: dir)
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
            NSLog("DropNotch: Ablage speichern fehlgeschlagen: \(error)")
        }
    }
}
