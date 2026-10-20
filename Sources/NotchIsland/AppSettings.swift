import AppKit
import SwiftUI

enum IslandSize: Int, CaseIterable, Identifiable {
    case compact, normal, large
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .compact: return "Компактный"
        case .normal: return "Обычный"
        case .large: return "Большой"
        }
    }

    func width(notch: CGFloat) -> CGFloat {
        switch self {
        case .compact: return max(400, notch + 215)
        case .normal: return max(440, notch + 250)
        case .large: return max(520, notch + 330)
        }
    }

    /// Сторона обложки в развёрнутом состоянии.
    var artSize: CGFloat {
        switch self {
        case .compact: return 80
        case .normal: return 84
        case .large: return 100
        }
    }

    /// Высота под строкой выреза.
    var bodyHeight: CGFloat {
        switch self {
        case .compact: return 120
        case .normal: return 132
        case .large: return 150
        }
    }
}

/// Все пользовательские настройки. Каждое изменение сразу пишется в UserDefaults.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    // Внешний вид
    @Published var size: IslandSize { didSet { d.set(size.rawValue, forKey: "set.size") } }
    /// -1 — открывать на последней использованной вкладке.
    @Published var defaultTab: Int { didSet { d.set(defaultTab, forKey: "set.defaultTab") } }
    @Published var accentFromArtwork: Bool { didSet { d.set(accentFromArtwork, forKey: "set.accentAuto") } }
    @Published var accentHex: String { didSet { d.set(accentHex, forKey: "set.accentHex") } }
    @Published var timerHex: String { didSet { d.set(timerHex, forKey: "set.timerHex") } }

    // Модули
    @Published var musicOn: Bool { didSet { d.set(musicOn, forKey: "set.music") } }
    @Published var lyricsOn: Bool { didSet { d.set(lyricsOn, forKey: "set.lyrics") } }
    /// Показывать только музыку: без YouTube и другого видео из браузеров и видеоплееров.
    @Published var musicOnly: Bool { didSet { d.set(musicOnly, forKey: "set.musicOnly") } }
    @Published var timerOn: Bool { didSet { d.set(timerOn, forKey: "set.timer") } }
    @Published var shelfOn: Bool { didSet { d.set(shelfOn, forKey: "set.shelf") } }
    @Published var clipboardOn: Bool { didSet { d.set(clipboardOn, forKey: "set.clipboard") } }
    @Published var screenshotOn: Bool { didSet { d.set(screenshotOn, forKey: "set.screenshot") } }
    @Published var batteryOn: Bool { didSet { d.set(batteryOn, forKey: "set.battery") } }
    @Published var bluetoothOn: Bool { didSet { d.set(bluetoothOn, forKey: "set.bluetooth") } }

    // Переводчик
    @Published var translatorOn: Bool { didSet { d.set(translatorOn, forKey: "set.translator") } }
    @Published var hotkey: Int { didSet { d.set(hotkey, forKey: "set.hotkey") } }
    @Published var translateViaClaude: Bool { didSet { d.set(translateViaClaude, forKey: "set.translateClaude") } }
    /// Ключ Anthropic API — в связке ключей, не в UserDefaults.
    @Published var apiKey: String { didSet { Keychain.set(apiKey) } }

    /// Клик по записи буфера сразу вставляет её в активное приложение (нужен доступ «Универсальный доступ»).
    @Published var autoPaste: Bool { didSet { d.set(autoPaste, forKey: "set.autoPaste") } }

    init() {
        func flag(_ k: String, _ def: Bool = true) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? def }
        let u = UserDefaults.standard
        size = IslandSize(rawValue: u.object(forKey: "set.size") as? Int ?? 1) ?? .normal
        defaultTab = u.object(forKey: "set.defaultTab") as? Int ?? -1
        accentFromArtwork = flag("set.accentAuto")
        accentHex = u.string(forKey: "set.accentHex") ?? "#0A84FF"
        timerHex = u.string(forKey: "set.timerHex") ?? "#FF9F0A"
        musicOn = flag("set.music")
        lyricsOn = flag("set.lyrics")
        musicOnly = flag("set.musicOnly")
        timerOn = flag("set.timer")
        shelfOn = flag("set.shelf")
        clipboardOn = flag("set.clipboard")
        screenshotOn = flag("set.screenshot")
        batteryOn = flag("set.battery")
        bluetoothOn = flag("set.bluetooth")
        autoPaste = flag("set.autoPaste", false)
        translatorOn = flag("set.translator")
        hotkey = u.object(forKey: "set.hotkey") as? Int ?? 0
        translateViaClaude = flag("set.translateClaude", false)
        apiKey = Keychain.get() ?? ""
    }

    func isEnabled(_ tab: IslandTab) -> Bool {
        switch tab {
        case .music: return musicOn
        case .timer: return timerOn
        case .shelf: return shelfOn
        case .clipboard: return clipboardOn
        }
    }

    var customAccent: Color {
        get { Color(hex: accentHex) }
        set { accentHex = newValue.hexString }
    }
    var timerColor: Color {
        get { Color(hex: timerHex) }
        set { timerHex = newValue.hexString }
    }
}

// MARK: - Color <-> hex

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count != 6 { s = "FFFFFF" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
