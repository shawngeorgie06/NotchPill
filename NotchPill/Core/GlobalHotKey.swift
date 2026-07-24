import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey registered via Carbon's RegisterEventHotKey.
/// Fires `onPressed` regardless of the frontmost app and needs no Accessibility
/// permission (unlike a CGEvent tap). Default combo: ⌥⌘R.
final class GlobalHotKey {
    var onPressed: () -> Void = {}

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: 0x4E_50_4B_52 /* 'NPKR' */, id: 1)

    /// Registers the hotkey. Default: ⌥⌘R (`kVK_ANSI_R` + cmd/option).
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_R),
                  modifiers: UInt32 = UInt32(cmdKey | optionKey)) {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var firedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            if firedID.id == me.hotKeyID.id {
                DispatchQueue.main.async { me.onPressed() }
            }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    deinit { unregister() }
}
