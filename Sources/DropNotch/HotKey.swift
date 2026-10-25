import Carbon.HIToolbox

/// Systemweites Tastenkürzel über Carbon `RegisterEventHotKey`. Anders als ein globaler
/// Tasten-Monitor braucht das keine Bedienungshilfen-Freigabe. Solange die Instanz lebt,
/// ist das Kürzel registriert.
final class HotKey {
    private static let signature: OSType = 0x444E_6368 // "DNch"

    private let id: UInt32
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// - Parameters:
    ///   - keyCode: Virtueller Tastencode, z. B. `kVK_ANSI_D`.
    ///   - modifiers: Carbon-Modifier, z. B. `controlKey | optionKey`.
    /// - Returns: `nil`, wenn das Kürzel schon von einer anderen App belegt ist.
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

    /// Carbon ruft den Handler auf dem Main-Thread auf.
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
