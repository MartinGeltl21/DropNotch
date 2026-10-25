import AppKit
import XCTest
@testable import DropNotch

/// Temporäre Umgebung für einen Test: eigener Ablage-Ordner, eigene Einstellungen und ein
/// Papierkorb, der nur mitschreibt – nichts davon berührt die echten Daten.
@MainActor
private final class Fixture {
    let root: URL
    let baseDir: URL
    let sourceDir: URL
    let defaults: UserDefaults
    private let suiteName = "DropNotchTests-\(UUID().uuidString)"
    private(set) var trashed: [URL] = []

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        baseDir = root.appendingPathComponent("Store", isDirectory: true)
        sourceDir = root.appendingPathComponent("Quelle", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func makeStore() -> ShelfStore {
        ShelfStore(baseDir: baseDir, defaults: defaults) { [weak self] url in
            self?.trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
    }

    func makeFile(_ name: String, contents: String = "Hallo") -> URL {
        let url = sourceDir.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: url)
        return url
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class ShelfStoreTests: XCTestCase {
    // MARK: - Verlinken

    func testAddReference() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let file = fixture.makeFile("Notiz.txt")

        store.add(fileURL: file)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(paths(store.items.map(\.url)), paths([file]))
        XCTAssertEqual(store.items.first?.isCopy, false)
        XCTAssertNotNil(store.items.first?.bookmark)
    }

    func testReferenceIsNotAddedTwice() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let file = fixture.makeFile("Notiz.txt")

        store.add(fileURL: file)
        store.add(fileURL: file)

        XCTAssertEqual(store.items.count, 1)
    }

    func testMissingFileIsIgnored() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()

        store.add(fileURL: fixture.sourceDir.appendingPathComponent("gibt-es-nicht.txt"))

        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Kopieren

    func testCopyModeCopiesIntoStore() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: Settings.copyFiles)
        let store = fixture.makeStore()
        let file = fixture.makeFile("Bericht.txt", contents: "Inhalt")

        store.add(fileURL: file)
        XCTAssertEqual(store.pendingItems.map(\.name), ["Bericht.txt"], "Platzhalter während des Kopierens")
        XCTAssertTrue(store.items.isEmpty)
        await waitUntil { store.pendingItems.isEmpty }

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(item.isCopy)
        XCTAssertEqual(item.sourceURL?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        XCTAssertTrue(item.url.path.hasPrefix(store.filesDir.path))
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "Inhalt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Original bleibt unangetastet")
    }

    func testCopyIsNotAddedTwice() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: Settings.copyFiles)
        let store = fixture.makeStore()
        let file = fixture.makeFile("Bericht.txt")

        store.add(fileURL: file)
        store.add(fileURL: file)
        XCTAssertEqual(store.pendingItems.count, 1, "Doppelt abgelegt, während die Kopie noch läuft")
        await waitUntil { store.pendingItems.isEmpty }
        store.add(fileURL: file)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.pendingItems.isEmpty)
    }

    // MARK: - Persistenz

    func testItemsSurviveNewStoreInstance() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        store.add(fileURL: fixture.makeFile("Notiz.txt"))
        store.add(text: "Hallo Welt")

        let reloaded = fixture.makeStore()

        XCTAssertEqual(reloaded.items.map(\.id), store.items.map(\.id))
        XCTAssertEqual(reloaded.items.map(\.isCopy), [false, true])
        XCTAssertEqual(paths(reloaded.items.map(\.url)), paths(store.items.map(\.url)))
    }

    func testRefreshDropsMissingFiles() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let file = fixture.makeFile("Notiz.txt")
        let kept = fixture.makeFile("Bleibt.txt")
        store.add(fileURL: file)
        store.add(fileURL: kept)

        try FileManager.default.removeItem(at: file)
        store.refresh()

        XCTAssertEqual(paths(store.items.map(\.url)), paths([kept]))
        XCTAssertEqual(paths(fixture.makeStore().items.map(\.url)), paths([kept]), "Bereinigte Liste wurde gespeichert")
    }

    // MARK: - Bilder, Text und Links

    func testSaveImage() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }

        store.add(image: image)

        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(item.isCopy)
        XCTAssertTrue(item.name.hasPrefix("Bild "))
        XCTAssertEqual(item.url.pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOf: item.url))
    }

    func testSaveText() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()

        store.add(text: "Einkaufsliste")

        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(item.isCopy)
        XCTAssertTrue(item.name.hasPrefix("Text "))
        XCTAssertEqual(item.url.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "Einkaufsliste")
    }

    func testSaveWebloc() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let link = URL(string: "https://www.example.com/seite?a=1")!

        store.add(webURL: link)
        store.add(webURL: link, title: "Beispiel: Seite/Unterseite")

        XCTAssertEqual(store.items.map(\.name), ["www.example.com.webloc", "Beispiel- Seite-Unterseite.webloc"])
        for item in store.items {
            let data = try Data(contentsOf: item.url)
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            XCTAssertEqual(plist["URL"], link.absoluteString)
        }
    }

    // MARK: - Drop

    func testDropPrefersFileOverText() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let file = fixture.makeFile("Notiz.txt")
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString("Text", forType: .string)

        XCTAssertTrue(store.handleDrop(pasteboard))

        XCTAssertEqual(paths(store.items.map(\.url)), paths([file]))
    }

    func testDropPrefersWebLinkOverText() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([URL(string: "https://example.com")! as NSURL])
        pasteboard.setString("Beispielseite", forType: NSPasteboard.PasteboardType("public.url-name"))

        XCTAssertTrue(store.handleDrop(pasteboard))

        XCTAssertEqual(store.items.map(\.name), ["Beispielseite.webloc"])
    }

    func testDropPlainText() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Nur ein Satz", forType: .string)

        XCTAssertTrue(store.handleDrop(pasteboard))

        XCTAssertEqual(store.items.first?.url.pathExtension, "txt")
    }

    func testDropOfEmptyPasteboardIsRejected() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        XCTAssertFalse(store.handleDrop(pasteboard))
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Entfernen

    func testRemoveTrashesOnlyCopies() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let file = fixture.makeFile("Notiz.txt")
        store.add(fileURL: file)
        store.add(text: "Kopie")
        let copy = store.items[1]

        store.remove(store.items[0])
        store.remove(copy)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(fixture.trashed, [copy.url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Verlinktes Original bleibt")
    }

    func testDragOutRemovesOnlyWhenEnabledAndDropped() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        store.add(fileURL: fixture.makeFile("Eins.txt"))
        store.add(fileURL: fixture.makeFile("Zwei.txt"))
        let dragged = [store.items[0]]

        store.dragEnded(dragged, operation: .copy)
        XCTAssertEqual(store.items.count, 2, "Einstellung ist standardmäßig aus")

        fixture.defaults.set(true, forKey: Settings.removeAfterDragOut)
        store.dragEnded(dragged, operation: [])
        XCTAssertEqual(store.items.count, 2, "Abgebrochener Drag entfernt nichts")

        store.dragEnded(dragged, operation: .copy)
        XCTAssertEqual(store.items.map(\.name), ["Zwei.txt"])
    }

    // MARK: - Hilfen

    /// Pfade ohne Symlink-Unterschiede (/var vs. /private/var aus aufgelösten Bookmarks).
    private func paths(_ urls: [URL]) -> [String] {
        urls.map { $0.resolvingSymlinksInPath().path }
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DropNotchTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
