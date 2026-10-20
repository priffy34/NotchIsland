import AppKit
import SwiftUI
import IOKit.ps

enum IslandTab: Int, CaseIterable { case music, timer, shelf, clipboard }

// MARK: - Общая модель

final class IslandModel: ObservableObject {
    @Published var expanded = false
    @Published var tab: IslandTab = .music
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var dropTargeted = false
    /// Показывать ли карточку со свежим скриншотом вместо обычной вкладки.
    @Published var shotVisible = false
    /// Показывать ли карточку переводчика (приоритетнее скриншота).
    @Published var translateVisible = false
    /// Содержимое развёрнутого острова «проявляется» на такт позже самой формы — так работают каскадные анимации появления.
    @Published var revealed = false
    /// Направление последней смены вкладки: +1 — вправо, −1 — влево, 0 — без сдвига (карточки).
    @Published var tabDir = 1
    /// Живая обратная связь от свайпа двумя пальцами (отдельный объект — чтобы не перерисовывать весь остров).
    let swipe = SwipeState()

    let settings: AppSettings
    let translator: TranslatorManager
    let music = MusicManager()
    let lyrics = LyricsManager()
    let timers = TimerManager()
    let battery = BatteryManager()
    let bluetooth = BluetoothManager()
    let shelf = ShelfManager()
    let clipboard = ClipboardManager()
    let screenshots = ScreenshotManager()

    init() {
        let s = AppSettings()
        settings = s
        translator = TranslatorManager(settings: s)
    }

    /// Контроллер подставляет сюда сворачивание острова (после выбора записи буфера и т. п.).
    var requestCollapse: (() -> Void)?

    /// Запас окна под свечение от обложки.
    static let glowPad: CGFloat = 28

    var sideWidth: CGFloat { bluetooth.toast != nil ? 104 : 56 }

    var expandedSize: CGSize {
        CGSize(width: settings.size.width(notch: notchSize.width),
               height: notchSize.height + settings.size.bodyHeight)
    }
    var windowSize: CGSize {
        CGSize(width: expandedSize.width + Self.glowPad * 2, height: expandedSize.height + Self.glowPad)
    }
    var hasActivity: Bool {
        music.isPlaying || timers.state != .idle || battery.showCharging || bluetooth.toast != nil
    }
    var collapsedSize: CGSize {
        CGSize(width: notchSize.width + (hasActivity ? sideWidth * 2 : 0), height: notchSize.height)
    }

    // MARK: Вкладки с учётом отключённых модулей

    var enabledTabs: [IslandTab] { IslandTab.allCases.filter { settings.isEnabled($0) } }

    /// Вкладка, которая реально показывается (если выбранная отключена — первая из доступных).
    var currentTab: IslandTab? {
        let tabs = enabledTabs
        return tabs.contains(tab) ? tab : tabs.first
    }

    /// Переключение вкладки. Направление публикуется чуть раньше самой смены,
    /// чтобы уходящая панель успела получить правильную анимацию ухода.
    /// `clearCards: false` — оставить открытой карточку скриншота/переводчика (смена не по клику пользователя).
    func select(_ new: IslandTab, clearCards: Bool = true) {
        let tabs = enabledTabs
        guard let cur = currentTab,
              let from = tabs.firstIndex(of: cur),
              let to = tabs.firstIndex(of: new) else { tab = new; return }
        guard new != cur || (clearCards && (shotVisible || translateVisible)) else { return }
        tabDir = to >= from ? 1 : -1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            if clearCards {
                self.shotVisible = false
                self.translateVisible = false
            }
            self.tab = new
        }
    }

    /// Вкладка, на которой остров открывается по умолчанию.
    func preferredTab() -> IslandTab? {
        let tabs = enabledTabs
        if let t = IslandTab(rawValue: settings.defaultTab), tabs.contains(t) { return t }
        return currentTab
    }
}

/// Смещение содержимого во время свайпа (резиновая лента). Меняется до сотни раз в секунду.
final class SwipeState: ObservableObject {
    @Published var x: CGFloat = 0
}

// MARK: - Таймер / секундомер

final class TimerManager: ObservableObject {
    enum Mode { case countdown, stopwatch }
    enum State { case idle, running, paused, finished }

    @Published private(set) var mode: Mode = .countdown
    @Published private(set) var state: State = .idle
    @Published private(set) var display: Int = 300   // секунды: остаток или прошедшее
    @Published private(set) var total: Int = 300

    var onFinish: (() -> Void)?

    private var endDate: Date?
    private var startDate: Date?
    private var base: TimeInterval = 0
    private var ticker: Timer?

    var progress: Double { total > 0 ? 1 - Double(display) / Double(total) : 0 }

    func setMode(_ m: Mode) {
        guard state == .idle, m != mode else { return }
        mode = m
        display = (m == .countdown) ? total : 0
    }

    func setDuration(minutes: Int) {
        guard state == .idle, mode == .countdown else { return }
        total = max(1, min(180, minutes)) * 60
        display = total
    }

    func adjust(minutes: Int) { setDuration(minutes: total / 60 + minutes) }

    func toggle() {
        switch state {
        case .idle, .finished: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    func reset() {
        stopTicker()
        state = .idle
        display = (mode == .countdown) ? total : 0
    }

    private func start() {
        switch mode {
        case .countdown:
            guard total > 0 else { return }
            display = total
            endDate = Date().addingTimeInterval(TimeInterval(total))
        case .stopwatch:
            base = 0
            display = 0
            startDate = Date()
        }
        state = .running
        startTicker()
    }

    private func pause() {
        switch mode {
        case .countdown: base = max(0, endDate?.timeIntervalSinceNow ?? 0)
        case .stopwatch: base += Date().timeIntervalSince(startDate ?? Date())
        }
        stopTicker()
        state = .paused
    }

    private func resume() {
        switch mode {
        case .countdown: endDate = Date().addingTimeInterval(base)
        case .stopwatch: startDate = Date()
        }
        state = .running
        startTicker()
    }

    private func tick() {
        switch mode {
        case .countdown:
            let r = endDate?.timeIntervalSinceNow ?? 0
            if r <= 0 { finish(); return }
            let v = Int(r.rounded(.up))
            if v != display { display = v }
        case .stopwatch:
            let v = Int(base + Date().timeIntervalSince(startDate ?? Date()))
            if v != display { display = v }
        }
    }

    private func finish() {
        stopTicker()
        display = 0
        state = .finished
        NSSound(named: "Glass")?.play()
        onFinish?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.state == .finished { self?.reset() }
        }
    }

    // Тикаем только пока таймер реально запущен; 4 раза в секунду с допуском.
    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

// MARK: - Батарея (событийно, без поллинга)

final class BatteryManager: ObservableObject {
    @Published private(set) var level = 100
    @Published private(set) var isPlugged = false
    @Published private(set) var showCharging = false

    /// Выключается из настроек: само чтение событий почти бесплатно, поэтому просто не показываем уведомление.
    var enabled = true

    private var source: CFRunLoopSource?
    private var hideToken = 0

    init() {
        read()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            Unmanaged<BatteryManager>.fromOpaque(ctx).takeUnretainedValue().update()
        }
        if let src = IOPSNotificationCreateRunLoopSource(cb, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        }
    }

    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let cap = d[kIOPSCurrentCapacityKey] as? Int { level = cap }
            isPlugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
    }

    private func update() {
        let wasPlugged = isPlugged
        read()
        if enabled && isPlugged && !wasPlugged {
            showCharging = true
            hideToken += 1
            let token = hideToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, self.hideToken == token else { return }
                self.showCharging = false
            }
        }
    }
}
