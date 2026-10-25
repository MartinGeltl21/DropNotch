import AppKit
import XCTest
@testable import DropNotch

/// Temporary environment for a test: its own shelf folder, its own settings and a
/// Trash that only records – none of it touches the real data.
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
        sourceDir = root.appendingPathComponent("Source", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func makeStore() -> ShelfStore {
        ShelfStore(baseDir: baseDir, defaults: defaults) { [weak self] url in
            self?.trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
    }

    func makeFile(_ name: String, contents: String = "Hello") -> URL {
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
    // MARK: - Linking

    func testAddReference() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let file = fixture.makeFile("Note.txt")

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
        let file = fixture.makeFile("Note.txt")

        store.add(fileURL: file)
        store.add(fileURL: file)

        XCTAssertEqual(store.items.count, 1)
    }

    func testMissingFileIsIgnored() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()

        store.add(fileURL: fixture.sourceDir.appendingPathComponent("does-not-exist.txt"))

        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Copying

    func testCopyModeCopiesIntoStore() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: Settings.copyFiles)
        let store = fixture.makeStore()
        let file = fixture.makeFile("Report.txt", contents: "Contents")

        store.add(fileURL: file)
        XCTAssertEqual(store.pendingItems.map(\.name), ["Report.txt"], "Placeholder while copying")
        XCTAssertTrue(store.items.isEmpty)
        await waitUntil { store.pendingItems.isEmpty }

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(item.isCopy)
        XCTAssertEqual(item.sourceURL?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        XCTAssertTrue(item.url.path.hasPrefix(store.filesDir.path))
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "Contents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Original stays untouched")
    }

    func testCopyIsNotAddedTwice() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: Settings.copyFiles)
        let store = fixture.makeStore()
        let file = fixture.makeFile("Report.txt")

        store.add(fileURL: file)
        store.add(fileURL: file)
        XCTAssertEqual(store.pendingItems.count, 1, "Added twice while the copy is still running")
        await waitUntil { store.pendingItems.isEmpty }
        store.add(fileURL: file)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.pendingItems.isEmpty)
    }

    // MARK: - Persistence

    func testItemsSurviveNewStoreInstance() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        store.add(fileURL: fixture.makeFile("Note.txt"))
        store.add(text: "Hello World")

        let reloaded = fixture.makeStore()

        XCTAssertEqual(reloaded.items.map(\.id), store.items.map(\.id))
        XCTAssertEqual(reloaded.items.map(\.isCopy), [false, true])
        XCTAssertEqual(paths(reloaded.items.map(\.url)), paths(store.items.map(\.url)))
    }

    func testRefreshDropsMissingFiles() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let file = fixture.makeFile("Note.txt")
        let kept = fixture.makeFile("Kept.txt")
        store.add(fileURL: file)
        store.add(fileURL: kept)

        try FileManager.default.removeItem(at: file)
        store.refresh()

        XCTAssertEqual(paths(store.items.map(\.url)), paths([kept]))
        XCTAssertEqual(paths(fixture.makeStore().items.map(\.url)), paths([kept]), "Cleaned-up list was saved")
    }

    // MARK: - Images, text and links

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
        XCTAssertTrue(item.name.hasPrefix("Image "))
        XCTAssertEqual(item.url.pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOf: item.url))
    }

    func testSaveText() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()

        store.add(text: "Shopping list")

        let item = try XCTUnwrap(store.items.first)
        XCTAssertTrue(item.isCopy)
        XCTAssertTrue(item.name.hasPrefix("Text "))
        XCTAssertEqual(item.url.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "Shopping list")
    }

    func testSaveWebloc() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let link = URL(string: "https://www.example.com/page?a=1")!

        store.add(webURL: link)
        store.add(webURL: link, title: "Example: Page/Subpage")

        XCTAssertEqual(store.items.map(\.name), ["www.example.com.webloc", "Example- Page-Subpage.webloc"])
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
        let file = fixture.makeFile("Note.txt")
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
        pasteboard.setString("Example Page", forType: NSPasteboard.PasteboardType("public.url-name"))

        XCTAssertTrue(store.handleDrop(pasteboard))

        XCTAssertEqual(store.items.map(\.name), ["Example Page.webloc"])
    }

    func testDropPlainText() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Just a sentence", forType: .string)

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

    // MARK: - Removing

    func testRemoveTrashesOnlyCopies() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        let file = fixture.makeFile("Note.txt")
        store.add(fileURL: file)
        store.add(text: "Copy")
        let copy = store.items[1]

        store.remove(store.items[0])
        store.remove(copy)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(fixture.trashed, [copy.url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Linked original remains")
    }

    func testDragOutRemovesOnlyWhenEnabledAndDropped() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        store.add(fileURL: fixture.makeFile("One.txt"))
        store.add(fileURL: fixture.makeFile("Two.txt"))
        let dragged = [store.items[0]]

        store.dragEnded(dragged, operation: .copy)
        XCTAssertEqual(store.items.count, 2, "Setting is off by default")

        fixture.defaults.set(true, forKey: Settings.removeAfterDragOut)
        store.dragEnded(dragged, operation: [])
        XCTAssertEqual(store.items.count, 2, "Cancelled drag removes nothing")

        store.dragEnded(dragged, operation: .copy)
        XCTAssertEqual(store.items.map(\.name), ["Two.txt"])
    }

    // MARK: - Helpers

    /// Paths without symlink differences (/var vs. /private/var from resolved bookmarks).
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
