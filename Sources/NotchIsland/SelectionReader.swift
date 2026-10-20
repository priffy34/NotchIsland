import AppKit
import ApplicationServices

/// Достаёт выделенный текст из активного приложения.
/// 1) Сначала через Accessibility (ничего не трогает) — работает в большинстве нативных приложений.
/// 2) Если не вышло (Electron, терминалы, браузеры) — имитирует ⌘C, читает буфер и тут же возвращает его прежнее содержимое.
enum SelectionReader {
    static func read(clipboard: ClipboardManager, done: @escaping (String?) -> Void) {
        if let t = axSelectedText(), !t.isEmpty { done(t); return }

        clipboard.beginInternalChange()
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount

        // Небольшая пауза: пользователь успевает отпустить модификаторы горячей клавиши.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            pressCopy()
            poll(pb, before: before, attempt: 0) { text in
                // Если ⌘C ничего не изменил, буфер остался прежним — не перезаписываем его.
                if pb.changeCount != before { restore(saved, to: pb) }
                clipboard.endInternalChange()
                done(text)
            }
        }
    }

    // MARK: - Accessibility

    private static func axSelectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Запасной путь через ⌘C

    private static func pressCopy() {
        // privateState — физически зажатые ⌃⌥ от горячей клавиши не примешиваются к событию.
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)    // 8 = «C»
        let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Ждём изменения буфера максимум ~0.5 с, проверяя каждые 50 мс (только пока идёт этот запрос).
    private static func poll(_ pb: NSPasteboard, before: Int, attempt: Int, done: @escaping (String?) -> Void) {
        if pb.changeCount != before { done(pb.string(forType: .string)); return }
        if attempt >= 10 { done(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            poll(pb, before: before, attempt: attempt + 1, done: done)
        }
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    private static func restore(_ s: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !s.isEmpty else { return }
        let items: [NSPasteboardItem] = s.map { dict in
            let it = NSPasteboardItem()
            for (t, data) in dict { it.setData(data, forType: t) }
            return it
        }
        pb.writeObjects(items)
    }
}
