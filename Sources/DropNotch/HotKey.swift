import Carbon.HIToolbox

/// System-wide keyboard shortcut via Carbon `RegisterEventHotKey`. Unlike a global
/// key monitor, this doesn't require Accessibility permission. The shortcut stays
/// registered for as long as the instance is alive.
final class HotKey {
    private static let signature: OSType = 0x444E_6368 // "DNch"

    private let id: UInt32
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// - Parameters:
    ///   - keyCode: Virtual key code, e.g. `kVK_ANSI_D`.
    ///   - modifiers: Carbon modifiers, e.g. `controlKey | optionKey`.
    /// - Returns: `nil` if the shortcut is already taken by another app.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        id = keyCode << 16 | modifiers
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            return Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().handle(event)
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Carbon calls the handler on the main thread.
    private func handle(_ event: EventRef) -> OSStatus {
        var pressed = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        guard status == noErr, pressed.signature == Self.signature, pressed.id == id else {
            return OSStatus(eventNotHandledErr)
        }
        MainActor.assumeIsolated { action() }
        return noErr
    }
}
