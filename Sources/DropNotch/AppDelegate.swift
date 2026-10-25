import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let vm = NotchViewModel()
    private let shelf = ShelfStore()
    private let music = MusicController()
    private var panel: NotchPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        NSApp.setActivationPolicy(.accessory)

        panel = NotchPanel()
        let hosting = NotchHostingView(rootView: NotchView(vm: vm, shelf: shelf, music: music))
        hosting.sizingOptions = []
        panel.contentView = hosting

        vm.onOpen = { [weak self] in
            self?.shelf.refresh()
            self?.music.refresh()
        }
        vm.attach(panel: panel, music: music)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.vm.updateScreen() }
        }

        setupStatusItem()
        updateHotKey()
    }

    // MARK: - Keyboard shortcut

    /// Registers ⌃⌥D as long as it is enabled in the settings.
    private func updateHotKey() {
        hotKey = nil
        guard UserDefaults.standard.bool(forKey: Settings.hotKeyEnabled) else { return }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.vm.toggle()
        }
    }

    // MARK: - Menu bar icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "DropNotch")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let defaults = UserDefaults.standard

        let openItem = item("Open Shelf", #selector(openNotch))
        if hotKey != nil {
            // Display only – the shortcut is triggered system-wide via `HotKey`.
            openItem.keyEquivalent = "d"
            openItem.keyEquivalentModifierMask = [.control, .option]
        }
        menu.addItem(openItem)
        menu.addItem(item("Clear Shelf (\(shelf.items.count))", #selector(clearShelf)))
        menu.addItem(item("Show Shelf Folder in Finder", #selector(revealStorage)))
        menu.addItem(.separator())
        menu.addItem(item("Copy Files Instead of Linking", #selector(toggleCopy),
                          on: defaults.bool(forKey: Settings.copyFiles)))
        menu.addItem(item("Remove from Shelf After Dragging Out", #selector(toggleRemoveAfterDragOut),
                          on: defaults.bool(forKey: Settings.removeAfterDragOut)))
        menu.addItem(item("Show Music in Closed Notch", #selector(toggleLiveActivity),
                          on: defaults.bool(forKey: Settings.showMusicWhenClosed)))
        menu.addItem(screenModeItem())
        menu.addItem(item("Keyboard Shortcut ⌃⌥D", #selector(toggleHotKey),
                          on: defaults.bool(forKey: Settings.hotKeyEnabled)))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DropNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    /// "Notch Position" submenu with a checkmark next to the active mode.
    private func screenModeItem() -> NSMenuItem {
        let submenu = NSMenu()
        let current = NotchScreenMode.current
        for mode in NotchScreenMode.allCases {
            let entry = item(mode.title, #selector(selectScreenMode(_:)), on: mode == current)
            entry.representedObject = mode.rawValue
            submenu.addItem(entry)
        }
        let parent = NSMenuItem(title: "Notch Position", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc private func openNotch() {
        vm.openPinned()
    }

    @objc private func clearShelf() { shelf.clear() }

    @objc private func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([shelf.filesDir])
    }

    @objc private func toggleCopy() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Settings.copyFiles), forKey: Settings.copyFiles)
    }

    @objc private func toggleRemoveAfterDragOut() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Settings.removeAfterDragOut), forKey: Settings.removeAfterDragOut)
    }

    @objc private func toggleLiveActivity() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Settings.showMusicWhenClosed), forKey: Settings.showMusicWhenClosed)
        vm.objectWillChange.send()
    }

    @objc private func selectScreenMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        UserDefaults.standard.set(rawValue, forKey: Settings.notchScreen)
        vm.updateScreen()
    }

    @objc private func toggleHotKey() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Settings.hotKeyEnabled), forKey: Settings.hotKeyEnabled)
        updateHotKey()
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
            alert.messageText = "Couldn’t Change Launch at Login"
            alert.informativeText = "Move DropNotch.app to the Applications folder and try again.\n\n\(error.localizedDescription)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
