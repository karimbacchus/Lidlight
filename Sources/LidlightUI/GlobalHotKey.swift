import Carbon.HIToolbox
import LidlightKit

/// The global shortcut ⌃⌘B, registered with Carbon (no accessibility permission needed).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) { self.onPress = onPress }

    deinit { unregister() }

    func register() {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress()
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard status == noErr else {
            Log.ui.error("Could not install the hot key handler (\(status))")
            return
        }
        let id = EventHotKeyID(signature: OSType(0x4C44_4C54), id: 1) // 'LDLT'
        let result = RegisterEventHotKey(
            UInt32(kVK_ANSI_B), UInt32(controlKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if result != noErr {
            Log.ui.error("Could not register ⌃⌘B (\(result))")
            hotKeyRef = nil
            unregister()
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
