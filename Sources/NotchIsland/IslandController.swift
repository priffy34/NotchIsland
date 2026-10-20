import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Разрешаем окну залезать в область меню-бара.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandController: NSObject {
    private let model = IslandModel()
    private var panel: NotchPanel!
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]

    private var pendingExpand: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var holdUntil = Date.distantPast
    private var menuOpen = false
    private let settingsWindow = SettingsWindow()
    private var settingsSub: AnyCancellable?
    private var appliedSize: IslandSize?
    private let hotkey = HotKey()
    private var appliedHotkey: Int?

    // жесты (свайп двумя пальцами = смена трека)
    private var swAbsX: CGFloat = 0          // сколько пальцы суммарно прошли по осям — для определения направления жеста
    private var swAbsY: CGFloat = 0
    private var swAccX: CGFloat = 0          // накопленный сдвиг по X (отрицательный — пальцы влево)
    private var swMode = 0                   // 0 — ещё не ясно, 1 — горизонтальный свайп, −1 — жест не наш
    private var swFired = false
    // чтобы отличать новый перетаскиваемый файл от «залежавшегося» содержимого drag-буфера
    private var lastUpCount = NSPasteboard(name: .drag).changeCount

    // MARK: - Запуск

    func start() {
        let view = IslandView(model: model) { [weak self] in
            DispatchQueue.main.async { self?.showMenu() }
        }
        let host = FirstMouseHostingView(rootView: view)
        if #available(macOS 13.0, *) { host.sizingOptions = [] }

        panel = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true          // в свёрнутом виде окно «прозрачно» для кликов
        panel.acceptsMouseMovedEvents = true
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()
        installMonitors()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        }

        model.timers.onFinish = { [weak self] in self?.onTimerFinished() }
        model.requestCollapse = { [weak self] in self?.setExpanded(false) }
        model.screenshots.onShot = { [weak self] in self?.onScreenshot() }
        hotkey.onPress = { [weak self] in self?.onTranslateHotkey() }

        // objectWillChange срабатывает ДО изменения значения — применяем настройки на следующем такте.
        settingsSub = model.settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }
        applySettings()
    }

    /// Приводит работающие модули в соответствие с настройками: выключенное не запускается и не потребляет ресурсы.
    private func applySettings() {
        let st = model.settings

        if appliedSize != st.size {
            appliedSize = st.size
            layout()
        }

        model.music.musicOnly = st.musicOnly
        if st.musicOn { model.music.start() } else { model.music.stop(); model.lyrics.reset() }
        if !st.timerOn { model.timers.reset() }
        if st.bluetoothOn { model.bluetooth.start() } else { model.bluetooth.stop() }
        model.battery.enabled = st.batteryOn
        if st.clipboardOn { model.clipboard.start() } else { model.clipboard.stop() }
        if st.screenshotOn { model.screenshots.start() } else { model.screenshots.stop(); model.shotVisible = false }
        let wantedHotkey: Int? = st.translatorOn ? st.hotkey : nil
        if appliedHotkey != wantedHotkey {
            appliedHotkey = wantedHotkey
            if let raw = wantedHotkey, let preset = HotkeyPreset(rawValue: raw) { hotkey.register(preset) }
            else { hotkey.unregister() }
        }
        if !st.shelfOn && model.tab == .shelf { model.tab = model.enabledTabs.first ?? .music }
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in self?.evaluate() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.evaluate(); return e
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] e in self?.handleScroll(e) }
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] e in
            self?.handleScroll(e); return e
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] _ in self?.handleRightClick() }
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] e in
            self?.handleRightClick(); return e
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in self?.mouseUp() }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] e in
            self?.mouseUp(); return e
        }
    }

    private func mouseUp() {
        lastUpCount = NSPasteboard(name: .drag).changeCount
        if model.dropTargeted { model.dropTargeted = false }
    }

    // MARK: - Геометрия

    private func notchScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout() {
        let s = notchScreen()
        screen = s

        var w: CGFloat = 185
        var h: CGFloat = max(24, NSStatusBar.system.thickness)
        if s.safeAreaInsets.top > 0 {
            h = s.safeAreaInsets.top
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
                w = s.frame.width - l.width - r.width
            }
        }
        model.notchSize = CGSize(width: w, height: h)

        let size = model.windowSize
        let frame = NSRect(x: s.frame.midX - size.width / 2,
                           y: s.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    /// Видимый прямоугольник острова в текущем состоянии.
    private func rect(expanded: Bool) -> NSRect {
        let s = expanded ? model.expandedSize : model.collapsedSize
        return NSRect(x: screen.frame.midX - s.width / 2,
                      y: screen.frame.maxY - s.height,
                      width: s.width, height: s.height)
    }

    /// Зона открытия — ровно физический вырез (+ 6 pt вверх, чтобы курсор у самой кромки экрана попадал).
    private var notchTrigger: NSRect {
        let n = model.notchSize
        return NSRect(x: screen.frame.midX - n.width / 2,
                      y: screen.frame.maxY - n.height,
                      width: n.width, height: n.height + 6)
    }

    // MARK: - Наведение

    private var isFileDrag: Bool {
        let pb = NSPasteboard(name: .drag)
        return pb.changeCount != lastUpCount && (pb.types?.contains(.fileURL) ?? false)
    }

    private func evaluate() {
        guard !menuOpen, Date() >= holdUntil else { return }
        let p = NSEvent.mouseLocation

        if model.expanded {
            let inside = rect(expanded: true).insetBy(dx: -10, dy: -10).contains(p)
            if inside {
                pendingCollapse?.cancel(); pendingCollapse = nil
            } else if pendingCollapse == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingCollapse = nil
                    let still = self.rect(expanded: true).insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation)
                    if !still && !self.menuOpen && Date() >= self.holdUntil { self.setExpanded(false) }
                }
                pendingCollapse = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
            return
        }

        // Свёрнуто: реагируем только на вырез.
        guard notchTrigger.contains(p) else {
            pendingExpand?.cancel(); pendingExpand = nil
            return
        }
        let pressed = NSEvent.pressedMouseButtons
        if pressed == 0 {
            // обычное наведение, небольшая задержка против случайных пролётов курсора
            if pendingExpand == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingExpand = nil
                    if self.notchTrigger.contains(NSEvent.mouseLocation) && NSEvent.pressedMouseButtons == 0 {
                        self.setExpanded(true)
                    }
                }
                pendingExpand = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        } else if pressed & 1 != 0, model.settings.shelfOn, isFileDrag {
            // тащим файл на вырез — сразу открываем полку
            pendingExpand?.cancel(); pendingExpand = nil
            setExpanded(true, tab: .shelf)
        } else {
            // зажата кнопка мыши по другой причине (перетаскивание окна и т.п.) — не открываемся
            pendingExpand?.cancel(); pendingExpand = nil
        }
    }

    private func setExpanded(_ value: Bool, tab: IslandTab? = nil) {
        if let tab {
            if model.expanded { model.select(tab, clearCards: false) } else { model.tab = tab }
        }
        guard model.expanded != value else { return }
        if value {
            if tab == nil {
                if model.settings.defaultTab >= 0, let t = model.preferredTab() {
                    model.tab = t                                      // выбранная в настройках вкладка
                } else if model.settings.timerOn, !model.music.isPlaying, model.timers.state != .idle {
                    model.tab = .timer                                 // «последняя», но идёт таймер, а музыки нет
                }
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            model.expanded = true
            panel.ignoresMouseEvents = false
            // Содержимое «проявляется» на такт позже формы — иначе SwiftUI не успеет отрисовать стартовый кадр
            // и каскадная анимация появления не сработает.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.model.expanded else { return }
                self.model.revealed = true
            }
        } else {
            model.dropTargeted = false
            model.shotVisible = false
            if model.translateVisible {
                model.translateVisible = false
                model.translator.cancel()                      // закрыли карточку — отменяем запрос
            }
            model.revealed = false
            model.expanded = false
            panel.ignoresMouseEvents = true
            resetSwipe()
        }
    }

    /// Свежий скриншот: раскрываем остров с миниатюрой и держим его открытым несколько секунд.
    /// Горячая клавиша переводчика: читаем выделение, показываем карточку возле выреза.
    private func onTranslateHotkey() {
        guard model.settings.translatorOn else { return }
        model.shotVisible = false
        model.tabDir = 0
        model.translateVisible = true
        model.translator.begin(clipboard: model.clipboard)
        holdUntil = Date().addingTimeInterval(14)
        setExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 14.1) { [weak self] in self?.evaluate() }
    }

    private func onScreenshot() {
        guard model.settings.screenshotOn else { return }
        model.translateVisible = false
        model.tabDir = 0
        model.shotVisible = true
        holdUntil = Date().addingTimeInterval(6)
        setExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in self?.evaluate() }
    }

    private func onTimerFinished() {
        guard model.settings.timerOn else { return }
        if model.expanded { model.select(.timer, clearCards: false) } else { model.tab = .timer }
        holdUntil = Date().addingTimeInterval(6)
        setExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in self?.evaluate() }
    }

    // MARK: - Жесты

    private func gestureZoneContainsMouse() -> Bool {
        let p = NSEvent.mouseLocation
        return model.expanded ? rect(expanded: true).contains(p) : notchTrigger.contains(p)
    }

    /// Можно ли сейчас листать треки свайпом.
    private func canSwipeTracks() -> Bool {
        guard model.settings.musicOn, model.music.track != nil else { return false }
        // в длинной полке горизонтальный скролл нужен самой полке
        if model.expanded, model.currentTab == .shelf, model.shelf.items.count > 4,
           !model.shotVisible, !model.translateVisible { return false }
        return true
    }

    /// Сбрасывает жест; сдвиг содержимого упруго возвращается на место.
    private func resetSwipe() {
        swAbsX = 0; swAbsY = 0; swAccX = 0; swMode = 0; swFired = false
        if model.swipe.x != 0 {
            withAnimation(Animation.spring(response: 0.34, dampingFraction: 0.9)) { model.swipe.x = 0 }
        }
    }

    /// Горизонтальный свайп двумя пальцами по острову или вырезу — следующий / предыдущий трек.
    /// Пока пальцы двигаются, содержимое «тянется» за ними (резиновая лента); после порога трек переключается.
    private func handleScroll(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas else { return }             // только тачпад / Magic Mouse
        guard gestureZoneContainsMouse() else {
            if swMode != 0 || swFired || model.swipe.x != 0 { resetSwipe() }
            return
        }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) { resetSwipe() }
        if !e.momentumPhase.isEmpty { return }                        // инерцию игнорируем
        guard !e.phase.isEmpty else { return }
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)

        if swFired || swMode < 0 {
            if ended { resetSwipe() }
            return
        }

        // Направление считаем по движению пальцев, независимо от настройки «натуральной» прокрутки.
        var dx = e.scrollingDeltaX
        let dy = e.scrollingDeltaY
        if !e.isDirectionInvertedFromDevice { dx = -dx }

        swAbsX += abs(dx)
        swAbsY += abs(dy)
        if swMode == 0, swAbsX + swAbsY > 6 {
            swMode = (swAbsX > swAbsY && canSwipeTracks()) ? 1 : -1
        }

        if swMode == 1 {
            swAccX += dx
            model.swipe.x = 26 * CGFloat(tanh(Double(swAccX) / 70))
            if abs(swAccX) > 44 {
                swFired = true
                fireSwipe(direction: swAccX < 0 ? 1 : -1)
                // без «отскока»: иначе поверх смены трека получалось ещё одно лишнее покачивание
                withAnimation(Animation.spring(response: 0.34, dampingFraction: 1.0)) { model.swipe.x = 0 }
            }
        }
        if ended { resetSwipe() }
    }

    private var lastSwipeFire = Date.distantPast

    private func fireSwipe(direction: Int) {
        guard canSwipeTracks() else { return }
        // защита от двойного срабатывания одного жеста (второй .began посреди свайпа)
        guard Date().timeIntervalSince(lastSwipeFire) > 0.45 else { return }
        lastSwipeFire = Date()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        model.music.send(direction > 0 ? .next : .previous)
    }

    /// Правый клик по острову или вырезу — пауза/воспроизведение.
    private func handleRightClick() {
        guard gestureZoneContainsMouse(), model.settings.musicOn, model.music.track != nil else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        model.music.send(.toggle)
    }

    // MARK: - Меню (⋯)

    @objc private func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openSettings() {
        settingsWindow.show(settings: model.settings)
    }

    private func showMenu() {
        menuOpen = true
        let m = NSMenu()
        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        let prefs = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        m.addItem(prefs)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        m.addItem(quit)
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        menuOpen = false
        evaluate()
    }
}
