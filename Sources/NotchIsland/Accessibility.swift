import AppKit
import ApplicationServices

/// Всё, что связано с доступом «Универсальный доступ» (нужен переводчику и автовставке).
enum Accessibility {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Системный диалог с просьбой выдать доступ.
    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Удаляет «залипшую» запись приложения из базы доступа (переключатель включён, а система его не признаёт)
    /// и сразу просит доступ заново.
    static func resetAndPrompt() {
        let id = Bundle.main.bundleIdentifier ?? "com.local.notchisland"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "Accessibility", id]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                prompt()
                openSettings()
            }
        }
    }

    /// Перезапуск приложения: иногда система отдаёт новый статус доступа только новому процессу.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
