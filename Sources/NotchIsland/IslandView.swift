import SwiftUI
import UniformTypeIdentifiers

// MARK: - Форма острова (плоский верх, скруглённый низ)

struct NotchShape: Shape {
    var topR: CGFloat
    var botR: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topR, botR) }
        set { topR = newValue.first; botR = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
                       control: CGPoint(x: rect.minX + topR, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - botR))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topR + botR, y: rect.maxY),
                       control: CGPoint(x: rect.minX + topR, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topR - botR, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - topR, y: rect.maxY - botR),
                       control: CGPoint(x: rect.maxX - topR, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - topR, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

func formatTime(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

// MARK: - Общие помощники для анимаций

/// Сдвиг + прозрачность + лёгкое размытие: основа переходов между панелями и треками.
struct SlideFadeModifier: ViewModifier {
    var x: CGFloat
    var opacity: Double
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .opacity(opacity)
            .blur(radius: blur)
    }
}

extension AnyTransition {
    static func slideFade(from x: CGFloat, blur: CGFloat = 0) -> AnyTransition {
        AnyTransition.modifier(active: SlideFadeModifier(x: x, opacity: 0, blur: blur),
                               identity: SlideFadeModifier(x: 0, opacity: 1, blur: 0))
    }
}

/// Каскадное появление: элемент всплывает с небольшой задержкой, а при закрытии быстро гаснет.
struct RevealModifier: ViewModifier {
    let on: Bool
    let delay: Double
    let dy: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : dy)
            .animation(on ? Animation.easeOut(duration: 0.34).delay(delay)
                          : Animation.easeIn(duration: 0.12), value: on)
    }
}

extension View {
    func reveal(_ on: Bool, _ delay: Double = 0, dy: CGFloat = 8) -> some View {
        modifier(RevealModifier(on: on, delay: delay, dy: dy))
    }
}

/// Кнопка с упругой реакцией на нажатие.
struct PressScaleStyle: ButtonStyle {
    var pressed: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressed : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Animation.spring(response: 0.26, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

// MARK: - Корневой вид

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var music: MusicManager
    @ObservedObject var timers: TimerManager
    @ObservedObject var battery: BatteryManager
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var shelf: ShelfManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var screenshots: ScreenshotManager
    let swipe: SwipeState
    let onMenu: () -> Void

    init(model: IslandModel, onMenu: @escaping () -> Void) {
        self.model = model
        self.music = model.music
        self.timers = model.timers
        self.battery = model.battery
        self.bluetooth = model.bluetooth
        self.shelf = model.shelf
        self.settings = model.settings
        self.clipboard = model.clipboard
        self.screenshots = model.screenshots
        self.swipe = model.swipe
        self.onMenu = onMenu
    }

    /// Акцент: из обложки или выбранный пользователем.
    private var accent: Color { settings.accentFromArtwork ? music.accent : settings.customAccent }
    private var timerColor: Color { settings.timerColor }

    // Открытие — упругое, закрытие — без отскока, мягкое и чуть более длинное.
    private let openSpring = Animation.spring(response: 0.46, dampingFraction: 0.78)
    private let closeSpring = Animation.spring(response: 0.5, dampingFraction: 1.0)
    private let resizeSpring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    private let paneSpring = Animation.spring(response: 0.4, dampingFraction: 0.86)
    private let trackSpring = Animation.spring(response: 0.42, dampingFraction: 0.84)
    private let accessorySpring = Animation.spring(response: 0.38, dampingFraction: 0.8)

    private var size: CGSize { model.expanded ? model.expandedSize : model.collapsedSize }
    private var shape: NotchShape {
        NotchShape(topR: model.expanded ? 12 : 6, botR: model.expanded ? 28 : 12)
    }

    // MARK: Состояния

    private enum Accessory: Int { case none, toast, charging, music, timer }

    /// Что показывается слева и справа от выреза (приоритеты те же, что и раньше).
    private var leftKind: Accessory {
        if bluetooth.toast != nil { return .toast }
        if battery.showCharging { return .charging }
        if music.isPlaying { return .music }
        if timers.state != .idle { return .timer }
        return .none
    }
    private var rightKind: Accessory {
        if bluetooth.toast != nil { return .toast }
        if battery.showCharging { return .charging }
        if timers.state != .idle { return .timer }
        if music.isPlaying { return .music }
        return .none
    }

    private var paneKey: Int {
        model.translateVisible ? 101 : (model.shotVisible ? 100 : (model.currentTab?.rawValue ?? -1))
    }
    private var musicPaneShown: Bool {
        settings.musicOn && model.currentTab == .music && !model.shotVisible && !model.translateVisible
    }
    private var glowActive: Bool {
        model.expanded && musicPaneShown && music.artwork != nil
    }

    // MARK: Обложка-«герой»: одна и та же картинка живёт и в свёрнутом, и в развёрнутом состоянии

    private var heroVisible: Bool { model.expanded ? musicPaneShown : leftKind == .music }

    /// Размер, радиус и положение центра относительно верхней середины острова.
    private var heroGeometry: (size: CGFloat, radius: CGFloat, dx: CGFloat, dy: CGFloat) {
        let nh = model.notchSize.height
        if model.expanded {
            let a = settings.size.artSize
            return (a, 12,
                    -model.expandedSize.width / 2 + 24 + a / 2,
                    nh + (settings.size.bodyHeight - 14 - a) / 2)
        } else {
            return (22, 5,
                    -model.collapsedSize.width / 2 + 12 + 11,
                    (nh - 22) / 2)
        }
    }

    // MARK: Спектр: столбики эквалайзера справа от выреза перетекают в полосу прогресса и обратно

    private var spectrumVisible: Bool { model.expanded ? musicPaneShown : rightKind == .music }

    /// Все координаты — от центра острова по X и от верха по Y (как у обложки).
    /// Полоса прогресса стоит ровно над кнопками: подписи времени имеют фиксированную ширину (см. MusicPane.timeLabelW).
    private var spectrumGeometry: (barsX: CGFloat, barsY: CGFloat, lineX: CGFloat, lineW: CGFloat, lineY: CGFloat) {
        let nh = model.notchSize.height
        let w = model.expandedSize.width
        let h = model.expandedSize.height
        let a = settings.size.artSize
        let side = MusicPane.timeLabelW + 6          // подпись времени + отступ до полосы
        return (barsX: model.notchSize.width / 2 + 56 - 21,
                barsY: nh / 2,
                lineX: 24 + a + 14 + side - w / 2,
                lineW: w - 48 - a - 14 - side * 2,
                lineY: h - 14 - 26 - 3 - 8)
    }

    // Содержимое выезжает каскадом уже после начала движения формы, а при закрытии быстро тает.
    private var expandedTransition: AnyTransition {
        AnyTransition.asymmetric(
            insertion: AnyTransition.identity,
            removal: AnyTransition.opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
                .animation(.easeIn(duration: 0.14))
        )
    }
    private var collapsedTransition: AnyTransition {
        AnyTransition.asymmetric(
            insertion: AnyTransition.opacity.animation(.easeOut(duration: 0.22).delay(0.16)),
            removal: AnyTransition.opacity.animation(.easeIn(duration: 0.08))
        )
    }
    private var accessoryTransition: AnyTransition {
        AnyTransition.scale(scale: 0.5).combined(with: .opacity)
    }
    private var paneTransition: AnyTransition {
        let d = CGFloat(model.tabDir) * 28
        return AnyTransition.asymmetric(insertion: .slideFade(from: d, blur: 4),
                                        removal: .slideFade(from: -d, blur: 4))
    }

    var body: some View {
        let hero = heroGeometry
        return ZStack(alignment: .top) {
            shape.fill(Color.black)
            glow
            if model.expanded {
                expandedContent.transition(expandedTransition)
            } else {
                collapsedContent.transition(collapsedTransition)
            }
            HeroArtwork(swipe: swipe,
                        image: music.artwork,
                        revision: music.artworkRevision,
                        dir: music.trackDir,
                        soft: music.artSoft,
                        size: hero.size, radius: hero.radius,
                        dx: hero.dx, dy: hero.dy,
                        visible: heroVisible,
                        interactive: model.expanded && heroVisible,
                        swipeGain: model.expanded ? 0.8 : 0.35,
                        onTap: { music.openSource() })
            let sp = spectrumGeometry
            SpectrumHero(p: model.expanded ? 1 : 0,
                         thick: music.scrub == nil ? 4 : 7,
                         music: music, accent: accent,
                         active: spectrumVisible,
                         barsX: sp.barsX, barsY: sp.barsY,
                         lineX: sp.lineX, lineW: sp.lineW, lineY: sp.lineY)
                // Не вкладка музыки — никакого полёта: столбики/полоса просто гаснут на месте.
                .transaction { t in
                    if !spectrumVisible { t.animation = nil }
                }
                // Свой, более медленный и линейный по времени ход (мягкость — внутри SpectrumHero).
                // Стоит ВНЕШНЕЙ обёрткой относительно transaction, поэтому «не вкладка музыки» всё равно отключает перелёт.
                .animation(Animation.linear(duration: model.expanded ? 1.04 : 0.85), value: model.expanded)
                .opacity(spectrumVisible ? 1 : 0)
                .animation(Animation.easeInOut(duration: spectrumVisible ? 0.22 : 0.08), value: spectrumVisible)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .shadow(color: accent.opacity(glowActive ? 0.55 : 0), radius: 18, x: 0, y: 6)
        // Порядок важен: при одновременном срабатывании побеждает самая «внутренняя» (первая) анимация.
        .animation(model.expanded ? openSpring : closeSpring, value: model.expanded)
        .animation(resizeSpring, value: model.collapsedSize)
        .animation(resizeSpring, value: model.expandedSize)
        .animation(paneSpring, value: paneKey)
        .animation(trackSpring, value: music.artworkRevision)
        .animation(accessorySpring, value: leftKind)
        .animation(accessorySpring, value: rightKind)
        .animation(Animation.easeInOut(duration: 0.25), value: glowActive)
        .animation(Animation.easeOut(duration: 0.15), value: music.scrub == nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    /// Свечение от обложки; при смене обложки старое плавно перетекает в новое.
    private var glow: some View {
        ZStack {
            shape
                .fill(RadialGradient(colors: [accent.opacity(0.28), accent.opacity(0)],
                                     center: .bottomLeading, startRadius: 0, endRadius: 280))
                .id(music.artworkRevision)
                .transition(.opacity)
        }
        .opacity(glowActive ? 1 : 0)
    }

    // MARK: Свёрнутое состояние: чуть шире выреза, инфо по бокам

    private var collapsedContent: some View {
        ZStack {
            Color.clear.frame(width: model.collapsedSize.width, height: model.notchSize.height)
            if leftKind != .none && leftKind != .music {
                leftAccessory
                    .padding(.leading, 12)
                    .frame(width: model.sideWidth, alignment: .leading)
                    .offset(x: -(model.notchSize.width + model.sideWidth) / 2)
            }
            if rightKind != .none && rightKind != .music {
                rightAccessory
                    .padding(.trailing, 12)
                    .frame(width: model.sideWidth, alignment: .trailing)
                    .offset(x: (model.notchSize.width + model.sideWidth) / 2)
            }
        }
        .frame(height: model.notchSize.height)
    }

    // Обложку слева рисует HeroArtwork — здесь для неё ничего не нужно.
    @ViewBuilder private var leftAccessory: some View {
        switch leftKind {
        case .toast:
            if let t = bluetooth.toast {
                Image(systemName: t.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(t.connected ? Color.white : Color.gray)
                    .transition(accessoryTransition)
            }
        case .charging:
            Image(systemName: "bolt.fill")
                .foregroundStyle(.green)
                .transition(accessoryTransition)
        case .timer:
            Image(systemName: timers.mode == .countdown ? "timer" : "stopwatch")
                .foregroundStyle(timers.state == .finished ? .red : timerColor)
                .transition(accessoryTransition)
        case .music, .none:
            EmptyView()
        }
    }

    @ViewBuilder private var rightAccessory: some View {
        switch rightKind {
        case .toast:
            if let t = bluetooth.toast {
                Text(t.connected ? t.name : "Отключено")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(t.connected ? Color.white : Color.gray)
                    .transition(accessoryTransition)
            }
        case .charging:
            Text("\(battery.level)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.green)
                .transition(accessoryTransition)
        case .timer:
            Text(formatTime(timers.display))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(timers.state == .finished ? .red : (timers.state == .paused ? timerColor.opacity(0.6) : timerColor))
                .transition(accessoryTransition)
        case .music, .none:
            EmptyView()          // столбики справа рисует SpectrumHero — он же перетекает в полосу прогресса
        }
    }

    // MARK: Развёрнутое состояние

    @ViewBuilder private var paneView: some View {
        Group {
            if model.translateVisible {
                TranslatePane(tr: model.translator, hasKey: !settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            } else if model.shotVisible, let shot = screenshots.latest {
                ShotPane(shot: shot, shelfOn: settings.shelfOn) {
                    model.shotVisible = false
                }
            } else {
                switch model.currentTab {
                case .music:
                    MusicPane(music: music, lyrics: model.lyrics, swipe: swipe,
                              showLyrics: settings.lyricsOn, accent: accent,
                              artSize: settings.size.artSize, revealed: model.revealed)
                case .timer:
                    TimerPane(timers: timers, base: timerColor)
                case .shelf:
                    ShelfPane(shelf: shelf)
                case .clipboard:
                    ClipboardPane(clipboard: clipboard) { item in
                        clipboard.restore(item, autoPaste: settings.autoPaste)
                        model.requestCollapse?()
                    }
                case nil:
                    Text("Все модули отключены")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            topBar.frame(height: model.notchSize.height)
            // ZStack, чтобы уходящая и приходящая панели накладывались друг на друга, а не делили высоту.
            ZStack {
                paneView
                    .id(paneKey)
                    .transition(paneTransition)
            }
            .reveal(model.revealed || musicPaneShown, 0.08)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .frame(maxHeight: .infinity)
        }
        .frame(width: model.expandedSize.width, height: model.expandedSize.height)
        .overlay(alignment: .topLeading) {
            ZStack {
                if model.dropTargeted {
                    // Отступы подобраны под форму острова: контур идёт параллельно стенкам (углы — концентрично).
                    DropOutline()
                        .padding(.top, model.notchSize.height + 3)
                        .padding(.bottom, 5)
                        .padding(.horizontal, 17)
                        .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(Animation.easeOut(duration: 0.2), value: model.dropTargeted)
            .allowsHitTesting(false)
        }
        .onDrop(of: settings.shelfOn ? [UTType.fileURL] : [], isTargeted: $model.dropTargeted) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    if let url { DispatchQueue.main.async { shelf.add(url) } }
                }
            }
            return true
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            tabStrip
                .padding(.leading, 24)
            Spacer(minLength: model.notchSize.width)
            Button(action: onMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle(pressed: 0.82))
            .padding(.trailing, 24)
        }
        .reveal(model.revealed, 0.03, dy: 0)
    }

    private static func icon(for tab: IslandTab) -> String {
        switch tab {
        case .music: return "music.note"
        case .timer: return "timer"
        case .shelf: return "tray.fill"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    /// Вкладки с «бегущей» подсветкой: капсула плавно переезжает от иконки к иконке.
    private var tabStrip: some View {
        let tabs = model.enabledTabs
        let cardShown = model.shotVisible || model.translateVisible
        var sel: Int? = nil
        if !cardShown, let cur = model.currentTab { sel = tabs.firstIndex(of: cur) }
        let selected = sel
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.16))
                .frame(width: 28, height: 22)
                .offset(x: CGFloat(selected ?? 0) * 32)
                .opacity(selected == nil ? 0 : 1)
            HStack(spacing: 4) {
                ForEach(tabs, id: \.self) { tab in
                    tabButton(tab, isSelected: tabs.firstIndex(of: tab) == selected)
                }
            }
        }
        .animation(Animation.spring(response: 0.36, dampingFraction: 0.78), value: selected)
    }

    private func tabButton(_ tab: IslandTab, isSelected: Bool) -> some View {
        Button {
            model.select(tab)
        } label: {
            Image(systemName: Self.icon(for: tab))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.gray)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
                .animation(Animation.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(PressScaleStyle(pressed: 0.88))
    }
}

// MARK: - Обложка

/// Сама картинка (или заглушка) без рамки — размер задаёт контейнер.
struct ArtworkFill: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.4, height: size * 0.4)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

/// Единая обложка острова. Она не пропадает и не появляется заново при раскрытии: непрерывно
/// меняет размер, скругление и положение — от миниатюры у выреза до большой карточки.
/// При смене трека новая картинка «въезжает» с той стороны, куда смахнули.
struct HeroArtwork: View {
    @ObservedObject var swipe: SwipeState
    let image: NSImage?
    let revision: Int
    let dir: Int
    let soft: Bool
    let size: CGFloat
    let radius: CGFloat
    let dx: CGFloat
    let dy: CGFloat
    let visible: Bool
    let interactive: Bool
    let swipeGain: CGFloat
    let onTap: () -> Void

    private var slide: AnyTransition {
        if soft { return .opacity }      // обложка опоздала за текстом — просто растворяется, без второго «въезда»
        let inEdge: Edge = dir >= 0 ? .trailing : .leading
        let outEdge: Edge = dir >= 0 ? .leading : .trailing
        return AnyTransition.asymmetric(
            insertion: AnyTransition.move(edge: inEdge).combined(with: .opacity),
            removal: AnyTransition.move(edge: outEdge).combined(with: .opacity))
    }

    var body: some View {
        ZStack {
            ArtworkFill(image: image, size: size)
                .id(revision)
                .transition(slide)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .scaleEffect(visible ? 1 : 0.82)
        .opacity(visible ? 1 : 0)
        .animation(Animation.easeInOut(duration: 0.22), value: visible)
        .offset(x: dx + swipe.x * swipeGain, y: dy)
        .allowsHitTesting(interactive)
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Спектр: эквалайзер ⇄ полоса прогресса

/// Столбики эквалайзера справа от выреза уступают место полосе прогресса в раскрытом острове (и обратно при закрытии).
/// `p` — единственный анимируемый параметр: 0 — свёрнуто, 1 — развёрнуто.
struct SpectrumHero: View, Animatable {
    var p: CGFloat
    var thick: CGFloat
    let music: MusicManager
    let accent: Color
    let active: Bool
    let barsX: CGFloat      // центр группы столбиков (от центра острова)
    let barsY: CGFloat      // центр столбиков по вертикали (от верха)
    let lineX: CGFloat      // левый край полосы (от центра острова)
    let lineW: CGFloat
    let lineY: CGFloat      // центр полосы по вертикали (от верха)

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(p, thick) }
        set { p = newValue.first; thick = newValue.second }
    }

    var body: some View {
        // Таймлайн крутится только пока спектр виден; в раскрытом виде он же плавно двигает полосу прогресса.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { ctx in
            Canvas { gc, size in
                draw(&gc, size: size, date: ctx.date)
            }
        }
        .allowsHitTesting(false)
    }

    /// Мягкая S-кривая (синусоида): медленный старт, быстрая середина, мягкое торможение.
    private func sine(_ x: CGFloat) -> CGFloat {
        let c = min(max(x, 0), 1)
        return 0.5 - 0.5 * cos(c * CGFloat.pi)
    }

    /// Раскрытие острова: столбики эквалайзера у выреза «стекаются» и растворяются, а на их месте
    /// проступает полоса прогресса — как и остальной интерфейс, она мягко всплывает снизу (6 pt) и растёт слева направо.
    /// Закрытие — то же самое в обратную сторону. `p` идёт по линейной шкале времени, плавность задаём здесь.
    private func draw(_ gc: inout GraphicsContext, size: CGSize, date: Date) {
        let cx = size.width / 2
        let t = date.timeIntervalSinceReferenceDate
        let pp = min(max(p, 0), 1)
        let th = max(thick, 1)
        let x0 = cx + lineX

        // доля проигранного
        let d = music.track?.duration ?? 0
        var rawFrac = 0.0
        if d > 0 {
            let e = music.scrub.map { $0 * d } ?? music.elapsed(at: date)
            rawFrac = min(max(e / d, 0), 1)
        }
        let frac = CGFloat(music.smoothedFraction(raw: rawFrac, date: date))
        let fillW = max(lineW * frac, th)

        // 1) полоса: сначала серая основа, чуть позже — проигранная часть
        let tr = sine((pp - 0.20) / 0.62)
        let fr = sine((pp - 0.30) / 0.62)
        let rise = 6 * (1 - tr)                                   // всплывает снизу, как остальные элементы панели
        if tr > 0.001 {
            let h = th * (0.5 + 0.5 * tr)
            let w = max(lineW * tr, 0.1)
            let r = CGRect(x: x0, y: lineY + rise - h / 2, width: w, height: h)
            gc.fill(Path(roundedRect: r, cornerRadius: min(w, h) / 2),
                    with: .color(Color.white.opacity(0.2 * Double(tr))))
        }
        if fr > 0.001, frac > 0 {
            let h = th * (0.5 + 0.5 * fr)
            let w = max(fillW * fr, 0.1)
            let r = CGRect(x: x0, y: lineY + rise - h / 2, width: w, height: h)
            gc.fill(Path(roundedRect: r, cornerRadius: min(w, h) / 2),
                    with: .color(accent.opacity(Double(fr))))
        }

        // 2) столбики эквалайзера: сходятся к центру группы, приседают и гаснут за первую треть раскрытия
        let bf = sine(pp / 0.4)
        guard bf < 0.999 else { return }
        let n = 4
        for i in 0..<n {
            let fi = CGFloat(i)
            let wave1 = sin(t * 5.4 + Double(i) * 1.7)
            let wave2 = sin(t * 3.1 + Double(i) * 0.9) * 0.5
            let k = CGFloat((wave1 + wave2 + 1.5) / 3)
            let h = (4 + 12 * k) * (1 - 0.7 * bf)
            let x = cx + barsX + (fi - 1.5) * 5 * (1 - 0.6 * bf)
            let r = CGRect(x: x - 1.5, y: barsY - h / 2, width: 3, height: h)
            gc.fill(Path(roundedRect: r, cornerRadius: min(3, h) / 2),
                    with: .color(accent.opacity(Double(1 - bf))))
        }
    }
}

// MARK: - Контур «бросьте файл»

/// Скруглённый прямоугольник с разными радиусами сверху и снизу (под форму острова).
struct OutlineShape: Shape {
    var rt: CGFloat
    var rb: CGFloat
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + rt, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: rt)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: rb)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: rb)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: rt)
        p.closeSubpath()
        return p
    }
}

/// Пунктир считается по реальной длине периметра, поэтому штрихи ложатся ровно и без «шва» в начале;
/// пока файл над островом, штрихи медленно бегут по контуру.
struct DropOutline: View {
    private let lineWidth: CGFloat = 1.5
    private let topRadius: CGFloat = 9
    private let bottomRadius: CGFloat = 23

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width - lineWidth, 1)
            let h = max(g.size.height - lineWidth, 1)
            let rt = min(topRadius, w / 2, h / 4)
            let rb = min(bottomRadius, w / 2, h / 4)
            let perimeter = (w - 2 * rt) + (w - 2 * rb) + 2 * (h - rt - rb) + CGFloat.pi * (rt + rb)
            let count = max((perimeter / 11).rounded(), 1)
            let step = perimeter / count
            let dash: CGFloat = 5 - lineWidth             // круглые концы добавляют по половине толщины с каждой стороны
            ZStack {
                OutlineShape(rt: rt, rb: rb, inset: lineWidth / 2)
                    .fill(Color.white.opacity(0.05))
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat((t * 9).truncatingRemainder(dividingBy: Double(step)))
                    OutlineShape(rt: rt, rb: rb, inset: lineWidth / 2)
                        .stroke(Color.white.opacity(0.6),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                                   dash: [dash, step - dash], dashPhase: phase))
                }
            }
        }
    }
}

// MARK: - Музыка

struct MusicPane: View {
    @ObservedObject var music: MusicManager
    @ObservedObject var lyrics: LyricsManager
    @ObservedObject var swipe: SwipeState
    let showLyrics: Bool
    let accent: Color
    let artSize: CGFloat
    let revealed: Bool

    private let trackSpring = Animation.spring(response: 0.42, dampingFraction: 0.84)

    /// Текст уезжает в сторону свайпа, новый въезжает с противоположной.
    private var slide: AnyTransition {
        let d = CGFloat(music.trackDir) * 30
        return AnyTransition.asymmetric(insertion: .slideFade(from: d, blur: 3),
                                        removal: .slideFade(from: -d, blur: 3))
    }

    var body: some View {
        HStack(spacing: 14) {
            // Место под обложку: саму картинку рисует HeroArtwork на уровне острова.
            Color.clear.frame(width: artSize, height: artSize)

            VStack(alignment: .leading, spacing: 3) {
                titleBlock

                if showLyrics {
                    LyricsLine(lyrics: lyrics, music: music)
                        .offset(x: swipe.x * 0.6)
                        .reveal(revealed, 0.10, dy: 6)
                } else {
                    Spacer(minLength: 0)
                }
                progress.reveal(revealed, 0.14, dy: 6)
                controls.reveal(revealed, 0.18, dy: 6)
            }
        }
        // Тексты запрашиваются лениво: только когда вкладка музыки реально открыта, и один раз на трек.
        .onAppear { if showLyrics { lyrics.load(for: music.track) } }
        .onChange(of: music.track) { t in if showLyrics { lyrics.load(for: t) } }
        .onChange(of: showLyrics) { on in
            if on { lyrics.load(for: music.track) } else { lyrics.reset() }
        }
    }

    private var titleBlock: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 3) {
                Text(music.track?.title ?? "Ничего не играет")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(music.track?.artist ?? "Запустите Яндекс Музыку")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !music.sourceName.isEmpty {
                        Text(music.sourceName)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(music.trackKey)
            .transition(slide)
        }
        .clipped()
        .offset(x: swipe.x)
        .opacity(1 - Double(min(abs(swipe.x), 30)) / 30 * 0.4)
        .animation(trackSpring, value: music.trackKey)
        .reveal(revealed, 0.06, dy: 6)
    }

    /// Интерактивная полоса: нажатие или перетаскивание — перемотка.
    /// При смене трека полоса заменяется целиком (а не «откатывается» назад линейной анимацией).
    private var progress: some View {
        ZStack {
            progressBar
                .id(music.trackKey)
                .transition(.opacity)
        }
        .frame(height: 16)
        .animation(Animation.easeInOut(duration: 0.3), value: music.trackKey)
    }

    /// Ширина подписей времени фиксирована — от неё зависит положение полосы, которую рисует SpectrumHero.
    static let timeLabelW: CGFloat = 32

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let d = music.track?.duration ?? 0
            let e = music.scrub.map { $0 * d } ?? music.elapsed(at: ctx.date)
            HStack(spacing: 6) {
                Text(formatTime(Int(e)))
                    .foregroundStyle(music.scrub == nil ? Color.secondary : Color.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: Self.timeLabelW, alignment: .leading)
                // Саму полосу рисует SpectrumHero на уровне острова (она перетекает из эквалайзера),
                // здесь остаётся только зона для нажатия и перетаскивания.
                GeometryReader { g in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    guard d > 0, g.size.width > 0 else { return }
                                    music.scrub = min(max(v.location.x / g.size.width, 0), 1)
                                }
                                .onEnded { v in
                                    if d > 0, g.size.width > 0 {
                                        music.seek(to: min(max(v.location.x / g.size.width, 0), 1) * d)
                                    }
                                    music.scrub = nil
                                }
                        )
                }
                .frame(height: 16)
                Text(d > 0 ? formatTime(Int(d)) : "--:--")
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: Self.timeLabelW, alignment: .trailing)
            }
            .font(.system(size: 10).monospacedDigit())
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            button("backward.fill", 15) { music.send(.previous) }
            playPause
            button("forward.fill", 15) { music.send(.next) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
    }

    /// Пауза и воспроизведение плавно перетекают друг в друга.
    private var playPause: some View {
        Button { music.send(.toggle) } label: {
            ZStack {
                Image(systemName: "play.fill")
                    .opacity(music.isPlaying ? 0 : 1)
                    .scaleEffect(music.isPlaying ? 0.4 : 1)
                Image(systemName: "pause.fill")
                    .opacity(music.isPlaying ? 1 : 0)
                    .scaleEffect(music.isPlaying ? 1 : 0.4)
            }
            .font(.system(size: 20))
            .foregroundStyle(.white)
            .frame(width: 30, height: 26)
            .contentShape(Rectangle())
            .animation(Animation.spring(response: 0.3, dampingFraction: 0.7), value: music.isPlaying)
        }
        .buttonStyle(PressScaleStyle(pressed: 0.82))
    }

    private func button(_ icon: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(pressed: 0.8))
    }
}

// MARK: - Полка для файлов

struct ShelfPane: View {
    @ObservedObject var shelf: ShelfManager

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(shelf.items.isEmpty ? "Полка" : "Полка · \(shelf.items.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !shelf.items.isEmpty {
                    iconButton("square.and.arrow.up") { shelf.airDrop() }
                        .transition(.opacity)
                    iconButton("trash") { shelf.clear() }
                        .transition(.opacity)
                }
            }
            .frame(height: 18)
            .animation(Animation.easeInOut(duration: 0.2), value: shelf.items.isEmpty)

            ZStack {
                if shelf.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 24, weight: .light))
                        Text("Перетащите файлы на остров")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items) { item in
                                tile(item)
                                    .transition(AnyTransition.scale(scale: 0.78).combined(with: .opacity))
                            }
                        }
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                        .animation(Animation.spring(response: 0.38, dampingFraction: 0.78),
                                   value: shelf.items.map { $0.id })
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Animation.easeInOut(duration: 0.22), value: shelf.items.isEmpty)
        }
    }

    private func tile(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 48, height: 48)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 66)
        }
        .frame(width: 70)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(alignment: .topTrailing) {
            Button { shelf.remove(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.gray, Color.black)
            }
            .buttonStyle(PressScaleStyle(pressed: 0.8))
            .offset(x: 5, y: -5)
        }
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL) }
    }

    private func iconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(pressed: 0.8))
    }
}

// MARK: - Таймер / секундомер

struct TimerPane: View {
    @ObservedObject var timers: TimerManager
    var base: Color = .orange

    private var running: Bool { timers.state == .running }

    private var tint: Color {
        switch timers.state {
        case .finished: return .red
        case .paused: return base.opacity(0.6)
        default: return base
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(formatTime(timers.display))
                    .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .animation(Animation.easeInOut(duration: 0.25), value: timers.state)
                Spacer()
                HStack(spacing: 10) {
                    toggleButton
                    resetButton
                }
            }

            middle

            HStack(spacing: 14) {
                modeButton("Таймер", .countdown)
                modeButton("Секундомер", .stopwatch)
            }
        }
    }

    /// Средняя зона: быстрые пресеты в покое, полоса прогресса на ходу.
    private var middle: some View {
        ZStack {
            if timers.mode == .countdown {
                if timers.state == .idle {
                    chips.transition(AnyTransition.opacity.combined(with: .scale(scale: 0.94)))
                } else {
                    bar.transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Animation.easeInOut(duration: 0.25), value: timers.state == .idle)
        .animation(Animation.easeInOut(duration: 0.25), value: timers.mode)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            chip("−1") { timers.adjust(minutes: -1) }
            ForEach([1, 5, 10, 25], id: \.self) { m in
                chip("\(m) м", highlighted: timers.total == m * 60) { timers.setDuration(minutes: m) }
            }
            chip("+1") { timers.adjust(minutes: 1) }
        }
        .frame(maxWidth: .infinity)
    }

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: g.size.width * CGFloat(min(max(timers.progress, 0), 1)))
                    .animation(Animation.linear(duration: 1.0), value: timers.progress)
            }
        }
        .frame(height: 5)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var toggleButton: some View {
        Button { timers.toggle() } label: {
            ZStack {
                Image(systemName: "play.fill")
                    .opacity(running ? 0 : 1)
                    .scaleEffect(running ? 0.4 : 1)
                Image(systemName: "pause.fill")
                    .opacity(running ? 1 : 0)
                    .scaleEffect(running ? 1 : 0.4)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.black)
            .frame(width: 34, height: 34)
            .background(Circle().fill(base))
            .contentShape(Circle())
            .animation(Animation.spring(response: 0.3, dampingFraction: 0.7), value: running)
        }
        .buttonStyle(PressScaleStyle(pressed: 0.88))
    }

    private var resetButton: some View {
        Button { timers.reset() } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(pressed: 0.88))
    }

    private func chip(_ title: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(highlighted ? Color.black : Color.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(highlighted ? base : Color.white.opacity(0.14)))
                .contentShape(Capsule())
                .animation(Animation.easeOut(duration: 0.18), value: highlighted)
        }
        .buttonStyle(PressScaleStyle(pressed: 0.9))
    }

    private func modeButton(_ title: String, _ mode: TimerManager.Mode) -> some View {
        Button { timers.setMode(mode) } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(timers.mode == mode ? Color.white : Color.gray)
                .contentShape(Rectangle())
                .animation(Animation.easeInOut(duration: 0.2), value: timers.mode)
        }
        .buttonStyle(.plain)
        .opacity(timers.state == .idle || timers.mode == mode ? 1 : 0.4)
        .animation(Animation.easeInOut(duration: 0.2), value: timers.state == .idle)
    }
}


// MARK: - Строка текста песни (синхронно со временем трека)

struct LyricsLine: View {
    @ObservedObject var lyrics: LyricsManager
    @ObservedObject var music: MusicManager

    var body: some View {
        // Таймлайн существует только пока открыта вкладка музыки; сама смена строки — бинарный поиск по массиву.
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let t = music.scrub.map { $0 * (music.track?.duration ?? 0) } ?? music.elapsed(at: ctx.date)
            content(lyrics.line(at: t))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(_ line: String?) -> some View {
        switch lyrics.state {
        case .ready:
            ZStack(alignment: .leading) {
                Text(line ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .id(line ?? "")
                    .transition(AnyTransition.asymmetric(
                        insertion: AnyTransition.opacity.combined(with: .offset(x: 0, y: 6)),
                        removal: AnyTransition.opacity.combined(with: .offset(x: 0, y: -6))))
            }
            .animation(Animation.easeInOut(duration: 0.26), value: line)
        case .loading: hint("Ищу текст…")
        case .notFound: hint("Текст не найден")
        case .noSync: hint("Нет синхронного текста")
        case .failed: hint("Не удалось загрузить текст")
        case .idle: EmptyView()
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.tertiary)
            .transition(.opacity)
    }
}

// MARK: - История буфера обмена

struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardManager
    let onPick: (ClipItem) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(clipboard.items.isEmpty ? "Буфер обмена" : "Буфер · \(clipboard.items.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !clipboard.items.isEmpty {
                    Button { clipboard.clear() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle(pressed: 0.8))
                    .transition(.opacity)
                }
            }
            .frame(height: 18)
            .animation(Animation.easeInOut(duration: 0.2), value: clipboard.items.isEmpty)

            ZStack {
                if clipboard.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 24, weight: .light))
                        Text("Скопируйте текст — он появится здесь")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 3) {
                            ForEach(clipboard.items) { item in
                                ClipRow(item: item) { onPick(item) }
                                    .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                            }
                        }
                        .animation(Animation.spring(response: 0.38, dampingFraction: 0.85),
                                   value: clipboard.items.map { $0.id })
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Animation.easeInOut(duration: 0.22), value: clipboard.items.isEmpty)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(item.preview.isEmpty ? "(пробелы)" : item.preview)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// Подсветка строки при нажатии (без @State — сборка из командной строки не находит макрос State).
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.07)))
            .animation(Animation.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Превью скриншота

struct ShotPane: View {
    let shot: Shot
    let shelfOn: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: shot.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 190, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .onTapGesture {
                    NSWorkspace.shared.open(shot.url)
                    onOpen()
                }
                .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider(object: shot.url as NSURL) }

            VStack(alignment: .leading, spacing: 4) {
                Label("Скриншот", systemImage: "camera.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                Text(shot.url.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(shelfOn ? "Клик — открыть.\nПеретащите — на полку\nили в любое окно."
                             : "Клик — открыть.\nПеретащите в любое окно.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


// MARK: - Переводчик

struct TranslatePane: View {
    @ObservedObject var tr: TranslatorManager
    let hasKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach(TranslatorManager.Mode.allCases, id: \.rawValue) { m in
                    Button { tr.run(m) } label: {
                        Text(m.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tr.mode == m ? Color.white : Color.gray)
                            .opacity(m != .translate && !hasKey ? 0.45 : 1)
                            .contentShape(Rectangle())
                            .animation(Animation.easeInOut(duration: 0.2), value: tr.mode)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if case .done(let text) = tr.state {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle(pressed: 0.8))
                    .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .frame(height: 18)
            .animation(Animation.easeInOut(duration: 0.2), value: tr.state)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if !tr.source.isEmpty {
                        Text(tr.source)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Animation.easeInOut(duration: 0.22), value: tr.state)
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var content: some View {
        switch tr.state {
        case .idle: EmptyView()
        case .reading: note("Читаю выделенный текст…")
        case .loading: note(tr.mode == .translate ? "Перевожу…" : "Думаю…")
        case .done(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        case .needsAccess:
            VStack(alignment: .leading, spacing: 6) {
                Text("Нужен доступ «Универсальный доступ». Включите Notch Island в списке — карточка сама заметит это. Если переключатель уже включён, но не помогает, нажмите «Сбросить».")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    pill("Открыть настройки") { Accessibility.openSettings() }
                    pill("Сбросить") { Accessibility.resetAndPrompt() }
                    pill("Перезапустить") { Accessibility.relaunch() }
                }
            }
            .transition(.opacity)
        case .accessGranted:
            Text("Доступ выдан ✓ Выделите текст и нажмите сочетание ещё раз.")
                .font(.system(size: 12))
                .foregroundStyle(Color.green)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
            .transition(.opacity)
    }
}
