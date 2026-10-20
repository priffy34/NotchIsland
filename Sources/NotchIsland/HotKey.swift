import AppKit
import Carbon.HIToolbox

/// Готовые сочетания клавиш для переводчика.
enum HotkeyPreset: Int, CaseIterable, Identifiable {
    case ctrlOptT, cmdOptT, ctrlOptCmdT
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .ctrlOptT: return "⌃⌥T"
        case .cmdOptT: return "⌘⌥T"
        case .ctrlOptCmdT: return "⌃⌥⌘T"
        }
    }

    var keyCode: UInt32 { UInt32(kVK_ANSI_T) }

    var modifiers: UInt32 {
        switch self {
        case .ctrlOptT: return UInt32(controlKey | optionKey)
        case .cmdOptT: return UInt32(cmdKey | optionKey)
        case .ctrlOptCmdT: return UInt32(controlKey | optionKey | cmdKey)
        }
    }
}

/// Глобальная горячая клавиша через Carbon. Работает по событиям, без таймеров и без прав на мониторинг ввода.
final class HotKey {
    var onPress: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ preset: HotkeyPreset) {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
                guard let ctx else { return noErr }
                Unmanaged<HotKey>.fromOpaque(ctx).takeUnretainedValue().onPress?()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4E495354), id: 1)   // 'NIST'
        RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }
}
