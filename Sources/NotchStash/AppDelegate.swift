import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let vm = NotchViewModel()
    private let shelf = ShelfStore()
    private let spotify = SpotifyController()
    private var panel: NotchPanel!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        NSApp.setActivationPolicy(.accessory)

        panel = NotchPanel()
        let hosting = NotchHostingView(rootView: NotchView(vm: vm, shelf: shelf, spotify: spotify))
        hosting.sizingOptions = []
        panel.contentView = hosting

        vm.onOpen = { [weak self] in
            self?.shelf.refresh()
            self?.spotify.refresh()
        }
        vm.attach(panel: panel, spotify: spotify)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.vm.updateScreen() }
        }

        setupStatusItem()
    }

    // MARK: - Menüleisten-Icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "NotchStash")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let defaults = UserDefaults.standard

        menu.addItem(item("Ablage öffnen", #selector(openNotch)))
        menu.addItem(item("Ablage leeren (\(shelf.items.count))", #selector(clearShelf)))
        menu.addItem(item("Ablage-Ordner im Finder zeigen", #selector(revealStorage)))
        menu.addItem(.separator())
        menu.addItem(item("Dateien kopieren statt verlinken", #selector(toggleCopy),
                          on: defaults.bool(forKey: Settings.copyFiles)))
        menu.addItem(item("Musik in geschlossener Notch zeigen", #selector(toggleLiveActivity),
                          on: defaults.bool(forKey: Settings.showMusicWhenClosed)))
        menu.addItem(item("Bei Anmeldung starten", #selector(toggleLaunchAtLogin),
                          on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "NotchStash beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    @objc private func openNotch() {
        vm.isPinned = true
        vm.open()
    }

    @objc private func clearShelf() { shelf.clear() }

    @objc private func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([shelf.filesDir])
    }

    @objc private func toggleCopy() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Settings.copyFiles), forKey: Settings.copyFiles)
    }

    @objc private func toggleLiveActivity() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Settings.showMusicWhenClosed), forKey: Settings.showMusicWhenClosed)
        vm.objectWillChange.send()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Autostart konnte nicht geändert werden"
            alert.informativeText = "Lege NotchStash.app in den Programme-Ordner und versuche es erneut.\n\n\(error.localizedDescription)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
