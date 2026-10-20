import AppKit
import Combine
import SwiftUI

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var bundleID: String?
}

/// Читает системный «Now Playing» (его публикует Яндекс Музыка, Spotify, Apple Music, браузеры и т. д.)
/// через долгоживущий perl-процесс с адаптером: никакого поллинга, обновления приходят по событиям.
final class MusicManager: ObservableObject {
    enum Command: Int { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    /// Растёт при каждой смене обложки — по нему SwiftUI понимает, что нужен переход между картинками.
    @Published private(set) var artworkRevision = 0
    /// Направление последней смены трека (+1 — вперёд, −1 — назад): задаёт сторону, с которой «въезжает» новый трек.
    @Published private(set) var trackDir = 1
    /// Растёт ТОЛЬКО при настоящей смене трека — по нему SwiftUI запускает переход текста и полосы.
    /// Мелкие правки метаданных (исполнитель, регистр, длительность) идут тихо, без повторной анимации.
    @Published private(set) var trackGen = 0
    /// Доля 0...1 во время перетаскивания по полосе прогресса (nil — не перематываем).
    @Published var scrub: Double?

    private var baseElapsed: Double = 0
    private var baseDate = Date()
    private var rate: Double = 1

    private var process: Process?
    private var buffer = Data()
    private let io = DispatchQueue(label: "notchisland.music.io")
    private var lastArtHash = 0

    // антидребезг переходных состояний при смене трека / перемотке
    private var currentKey: String?          // нормализованное название трека, который сейчас на экране
    private var currentDuration: Double = 0
    private var prevKey: String?             // трек, который уходил при последней смене
    private var lastCommit = Date.distantPast
    private var staleWork: DispatchWorkItem?
    // Новая обложка, которая пришла раньше названия: ждёт «своего» трека, чтобы сменились они вместе.
    private var stashArt: NSImage?
    private var stashAccent: Color?
    private var stashTime = Date.distantPast
    private var stashWork: DispatchWorkItem?
    private var artKey: String?
    private var emptyWork: DispatchWorkItem?
    private var artCheckWork: DispatchWorkItem?
    private var pauseWork: DispatchWorkItem?
    private var seekLockUntil = Date.distantPast
    private var dirWork: DispatchWorkItem?

    /// Новый трек ждёт «в кулуарах», пока вместе с ним не приедет обложка, — и показывается одним махом.
    private struct Pending {
        var key: String
        var track: Track
        var art: NSImage?
        var accent: Color?
        var hasArt: Bool
        var elapsed: Double
        var playing: Bool
        var stamp: Date
        var since: Date
    }
    private var pending: Pending?
    private var commitWork: DispatchWorkItem?

    /// Скрывать всё, что не музыка: YouTube и другое видео в браузере, видеоплееры, мессенджеры.
    var musicOnly = true {
        didSet {
            guard oldValue != musicOnly else { return }
            io.async { [weak self] in
                guard let self, let raw = self.lastRaw else { return }
                self.lastArtHash = 0
                self.handle(raw)
            }
        }
    }
    private var lastRaw: [String: Any]?       // только на очереди io

    private var script: String? { Bundle.main.path(forResource: "mediaremote", ofType: "pl") }
    private var dylib: String? { Bundle.main.path(forResource: "libmradapter", ofType: "dylib") }

    // MARK: - Запуск потока

    private var wanted = false

    func start() {
        wanted = true
        guard process == nil, let script, let dylib else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, dylib, "adapter_stream"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.io.async { self?.ingest(d) }
        }
        // Перезапускаем только если процесс упал сам: при stop() ссылка process уже сброшена.
        p.terminationHandler = { [weak self, weak p] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let self, self.wanted, self.process === p else { return }
                self.process = nil
                self.start()
            }
        }
        do { try p.run(); process = p } catch { process = nil }
    }

    /// Останавливает фоновый процесс адаптера и сбрасывает состояние (модуль выключен в настройках).
    func stop() {
        wanted = false
        let p = process
        process = nil
        (p?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p?.terminate()
        emptyWork?.cancel(); emptyWork = nil
        artCheckWork?.cancel(); artCheckWork = nil
        pauseWork?.cancel(); pauseWork = nil
        cancelPending()
        track = nil; isPlaying = false
        artwork = nil; accent = .white; artworkRevision += 1
        currentKey = nil; artKey = nil; prevKey = nil
        staleWork?.cancel(); staleWork = nil
        stashWork?.cancel(); stashWork = nil; stashArt = nil
        trackGen += 1
        io.async { [weak self] in self?.buffer.removeAll(); self?.lastRaw = nil }
    }

    // MARK: - Разбор вывода (на фоновой очереди)

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        lastRaw = obj

        // Не музыка (YouTube в браузере, видеоплеер…) — для острова это «ничего не играет».
        if musicOnly && !Self.isMusicSource(obj["bundle"] as? String) {
            lastArtHash = 0
            DispatchQueue.main.async { [weak self] in
                self?.apply([:], art: nil, accent: nil, hasArt: false)
            }
            return
        }

        var image: NSImage?
        var accent: Color?
        var hasArt = false
        if let b64 = obj["artwork"] as? String, !b64.isEmpty {
            hasArt = true
            let h = b64.hashValue
            if h != lastArtHash {
                lastArtHash = h
                if let d = Data(base64Encoded: b64), let img = NSImage(data: d) {
                    image = img
                    if let c = img.dominantColor() { accent = Color(nsColor: c) }
                }
            }
        }
        // Событие без обложки НЕ означает «обложки нет» — часто это переходный момент.
        DispatchQueue.main.async { [weak self] in
            self?.apply(obj, art: image, accent: accent, hasArt: hasArt)
        }
    }

    /// Браузеры и видеоприложения не считаем музыкой. Неизвестный источник не отсекаем.
    static func isMusicSource(_ bundle: String?) -> Bool {
        guard let raw = bundle, !raw.isEmpty else { return true }
        let b = raw.lowercased()
        let notMusic = [
            "safari", "chrome", "chromium", "firefox", "thebrowser", "brave", "edgemac", "opera",
            "vivaldi", "orion", "browser", "youtube",
            "vlc", "iina", "quicktime", "mpv", "infuse", "kodi", "plex", "netflix", "twitch",
            "com.apple.tv", "podcasts", "zoom", "telegram", "whatsapp", "discord", "facetime"
        ]
        return !notMusic.contains(where: { b.contains($0) })
    }

    // MARK: - Применение (главный поток)

    private func apply(_ obj: [String: Any], art: NSImage?, accent: Color?, hasArt: Bool) {
        guard wanted else { return }        // запоздалое событие после выключения модуля
        let title = (obj["title"] as? String) ?? ""
        let artist = (obj["artist"] as? String) ?? ""

        // Пустое состояние во время переключения — не сбрасываем сразу, ждём 1.5 с.
        if title.isEmpty && artist.isEmpty {
            if emptyWork == nil && (track != nil || pending != nil) {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.emptyWork = nil
                    self.cancelPending()
                    self.track = nil; self.isPlaying = false
                    self.artwork = nil; self.accent = .white; self.artworkRevision += 1
                    self.currentKey = nil; self.artKey = nil; self.prevKey = nil
                    self.trackGen += 1
                }
                emptyWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
            }
            return
        }
        emptyWork?.cancel(); emptyWork = nil

        let t = Track(title: title, artist: artist,
                      album: (obj["album"] as? String) ?? "",
                      duration: (obj["duration"] as? Double) ?? 0,
                      bundleID: obj["bundle"] as? String)
        // Идентичность трека — только нормализованное название (+ длительность при явном конфликте).
        // Исполнитель в ключ НЕ входит: плееры дописывают фиты/меняют строку исполнителя уже после смены трека,
        // и раньше это давало второй переход.
        let key = Self.norm(title)
        // Длительность в ключ не берём: плеер присылает поля по частям, и «название нового + длительность старого»
        // раньше выглядело как смена трека — отсюда второй и третий переходы.
        let isCurrent = currentKey != nil && key == currentKey
        let playing = (obj["playing"] as? Bool) ?? false
        var r = max((obj["rate"] as? Double) ?? 1, 0)
        if playing && r == 0 { r = 1 }
        rate = r
        let el = (obj["elapsed"] as? Double) ?? 0

        if isCurrent {
            // Тот же трек: просто обновляем данные, никаких переходов.
            cancelPending()
            staleWork?.cancel(); staleWork = nil
            if t.duration > 0 { currentDuration = t.duration }
            if t != track { track = t }
            if hasArt { artKey = key }
            if let art {
                // Новая обложка при прежнем названии: либо она обогнала название (тогда смена будет общей),
                // либо подъехала позже. Ждём 0.4 с; если названия не будет — меняем обложку с анимацией.
                stashArt = art; stashAccent = accent; stashTime = Date()
                stashWork?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.applyStashedArt() }
                stashWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
            }
            if Date() >= seekLockUntil {
                baseElapsed = el
                baseDate = Date()
            }
            setPlaying(playing)
            return
        }

        // Запоздалый снимок УХОДЯЩЕГО трека сразу после смены (B → A → B давало двойной переход): не применяем.
        // Если за это время никто не подтвердил текущий трек, перепроверяем последний снимок.
        if let pk = prevKey, key == pk, currentKey != nil,
           Date().timeIntervalSince(lastCommit) < 0.9 {
            staleWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.staleWork = nil
                self.prevKey = nil
                self.io.async { [weak self] in
                    guard let self, let raw = self.lastRaw else { return }
                    self.lastArtHash = 0
                    self.handle(raw)
                }
            }
            staleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
            return
        }

        // Первый трек после тишины показываем сразу.
        if currentKey == nil {
            commit(Pending(key: key, track: t, art: art, accent: accent, hasArt: hasArt,
                           elapsed: el, playing: playing, stamp: Date(), since: Date()))
            setPlaying(playing)
            return
        }

        // Смена трека. Плеер присылает название и обложку отдельными событиями — собираем их вместе
        // и показываем ОДИН переход (раньше текст и картинка переключались по очереди — выглядело как два раза).
        var p = pending?.key == key
            ? pending!
            : Pending(key: key, track: t, art: nil, accent: nil, hasArt: false,
                      elapsed: el, playing: playing, stamp: Date(), since: Date())
        p.track = t
        p.elapsed = el; p.playing = playing; p.stamp = Date()
        if hasArt { p.hasArt = true }
        if let art { p.art = art; p.accent = accent }
        if p.art == nil, let a = stashArt, Date().timeIntervalSince(stashTime) < 1.2 {
            p.art = a; p.accent = stashAccent; p.hasArt = true
            stashArt = nil; stashWork?.cancel(); stashWork = nil
        }
        pending = p
        setPlaying(playing)

        if p.art != nil { schedule(p, wait: 0); return }

        // Тот же альбом → обложка почти наверняка та же, ждать почти нечего.
        let sameAlbum = !t.album.isEmpty && t.album == track?.album
        let wait: Double = (p.hasArt && sameAlbum) ? 0.1 : 0.55
        schedule(p, wait: max(0.02, wait - Date().timeIntervalSince(p.since)))
    }

    /// Между двумя сменами трека проходит минимум `commitCooldown` с: анимация не может сыграть дважды подряд.
    /// Пока ждём, пришедший снимок текущего трека отменяет ожидающую смену (это был запоздалый снимок).
    private let commitCooldown = 0.75

    private func schedule(_ p: Pending, wait: Double) {
        let cool = max(0, commitCooldown - Date().timeIntervalSince(lastCommit))
        let delay = max(wait, cool)
        if delay <= 0.001 { commit(p); return }
        commitWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let pend = self.pending else { return }
            self.commit(pend)
        }
        commitWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Обложка подъехала позже названия: меняем её с той же анимацией, что и при смене трека (без «щелчка»).
    private func applyStashedArt() {
        stashWork = nil
        guard wanted, let art = stashArt else { return }
        stashArt = nil
        artwork = art
        accent = stashAccent ?? .white
        if currentKey != nil { artKey = currentKey }
        artworkRevision += 1
    }

    private func cancelPending() {
        commitWork?.cancel(); commitWork = nil
        pending = nil
    }

    /// Единственное место, где меняется показанный трек: название, обложка и цвет — одним обновлением.
    private func commit(_ pIn: Pending) {
        var p = pIn
        if p.art == nil, let a = stashArt, Date().timeIntervalSince(stashTime) < 1.2 {
            p.art = a; p.accent = stashAccent; p.hasArt = true
        }
        stashArt = nil; stashWork?.cancel(); stashWork = nil
        cancelPending()
        staleWork?.cancel(); staleWork = nil
        if currentKey != p.key { prevKey = currentKey }
        currentKey = p.key
        currentDuration = p.track.duration
        lastCommit = Date()
        trackGen += 1
        seekLockUntil = .distantPast
        track = p.track
        if p.hasArt { artKey = p.key }
        if let art = p.art {
            artwork = art
            accent = p.accent ?? .white
            artworkRevision += 1
        }

        var el = p.elapsed
        if p.playing { el += max(0, Date().timeIntervalSince(p.stamp)) * rate }
        if p.track.duration > 0, el > p.track.duration + 1 { el = 0 }
        baseElapsed = el
        baseDate = Date()

        // Старую обложку держим, пока не придёт новая; если за 2 с её нет — убираем.
        artCheckWork?.cancel(); artCheckWork = nil
        if artKey != p.key {
            let key = p.key
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.currentKey == key, self.artKey != key else { return }
                self.artwork = nil; self.accent = .white; self.artworkRevision += 1
            }
            artCheckWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: w)
        }
    }

    /// Состояние «играет»: переход в паузу применяем с задержкой, чтобы не мигать между треками.
    private func setPlaying(_ playing: Bool) {
        if playing {
            pauseWork?.cancel(); pauseWork = nil
            if !isPlaying { isPlaying = true }
        } else if isPlaying, pauseWork == nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pauseWork = nil
                self.isPlaying = false
            }
            pauseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
        }
    }

    // MARK: - Публичное API для UI

    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return baseElapsed }
        let v = baseElapsed + date.timeIntervalSince(baseDate) * rate
        if let d = track?.duration, d > 0 { return min(v, d) }
        return v
    }

    /// Ключ текущего трека для SwiftUI (`.id`).
    var trackKey: String { track == nil ? "" : String(trackGen) }

    /// Название без регистра, пробелов и хвостов в скобках — «Song» и «Song (feat. X)» считаем одним треком.
    private static func norm(_ s: String) -> String {
        let base = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = base
            .replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? base : stripped
    }

    /// Направление запоминаем сразу в момент команды — настоящая смена трека придёт от плеера позже,
    /// и к этому моменту уходящий вид уже будет знать, в какую сторону уезжать.
    private func markDirection(_ d: Int) {
        trackDir = d
        dirWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.trackDir = 1 }
        dirWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func send(_ cmd: Command) {
        if cmd == .next { markDirection(1) }
        if cmd == .previous { markDirection(-1) }
        if cmd == .toggle {
            baseElapsed = elapsed(at: Date())
            baseDate = Date()
            isPlaying.toggle()      // оптимистично, реальное состояние придёт событием
        }
        guard let script, let dylib else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [script, dylib, "adapter_send"]
            p.environment = ["MR_CMD": String(cmd.rawValue)]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// Перемотка (секунды от начала трека).
    func seek(to seconds: Double) {
        baseElapsed = max(0, seconds)
        baseDate = Date()
        seekLockUntil = Date().addingTimeInterval(1.5)
        guard let script, let dylib else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [script, dylib, "adapter_seek"]
            p.environment = ["MR_SEEK": String(seconds)]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    var sourceName: String {
        let b = (track?.bundleID ?? "").lowercased()
        if b.isEmpty { return "" }
        if b.contains("yandex") && (b.contains("music") || b.contains("desktop")) { return "Яндекс Музыка" }
        if b.contains("spotify") { return "Spotify" }
        if b == "com.apple.music" { return "Apple Music" }
        if ["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "browser"].contains(where: { b.contains($0) }) {
            return "Браузер"
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: track?.bundleID ?? "") {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return ""
    }

    func openSource() {
        guard let id = track?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}


// MARK: - Доминантный цвет обложки (считается один раз на трек, на 16×16 пикселях)

extension NSImage {
    func dominantColor() -> NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 16, h = 16
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let rr = Double(px[i]) / 255, gg = Double(px[i + 1]) / 255, bb = Double(px[i + 2]) / 255
            let mx = max(rr, gg, bb), mn = min(rr, gg, bb)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            let weight = 0.03 + sat * sat * mx          // яркие насыщенные пиксели важнее
            r += rr * weight; g += gg * weight; b += bb * weight; total += weight
        }
        guard total > 0 else { return nil }
        let base = NSColor(red: r / total, green: g / total, blue: b / total, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
        base.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
        return NSColor(hue: hue, saturation: min(1, sat * 1.1), brightness: max(0.7, bri), alpha: 1)
    }
}
