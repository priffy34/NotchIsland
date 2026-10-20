import Foundation

struct LyricLine {
    let time: Double
    let text: String
}

/// Синхронные тексты из LRCLIB (https://lrclib.net).
///
/// Принципы «не тащить лишнее»:
/// • грузим только когда остров открыт на вкладке музыки (вызов `load` идёт из вида), а не на каждую смену трека;
/// • на трек — один лёгкий запрос `/api/get`; тяжёлый `/api/search` только если `/get` вернул 404;
/// • результат (в том числе «не найдено») кэшируется в памяти, повторно трек не запрашивается;
/// • при смене трека запрос в полёте отменяется.
final class LyricsManager: ObservableObject {
    enum State: Equatable { case idle, loading, ready, noSync, notFound, failed }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [LyricLine] = []

    private struct Entry { let state: State; let lines: [LyricLine] }

    private var cache: [String: Entry] = [:]
    private var order: [String] = []          // для вытеснения самых старых
    private let cacheLimit = 30

    private var currentKey: String?
    private var task: URLSessionDataTask?
    private var token = 0

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "NotchIsland/1.0 (macOS notch widget)"]
        return URLSession(configuration: c)
    }()

    // MARK: - API

    func load(for track: Track?) {
        guard let track, !track.title.isEmpty else { reset(); return }
        let key = [track.title, track.artist, track.album, String(Int(track.duration.rounded()))].joined(separator: "\u{1}")
        if key == currentKey { return }               // этот трек уже загружен или грузится
        currentKey = key
        task?.cancel(); task = nil
        token += 1

        if let hit = cache[key] {
            state = hit.state; lines = hit.lines
            return
        }
        state = .loading
        lines = []
        fetch(track, key: key, token: token)
    }

    /// Текущая строка для момента `t` (секунды от начала трека). Бинарный поиск.
    func line(at t: Double) -> String? {
        guard state == .ready, !lines.isEmpty else { return nil }
        let x = t + 0.25                              // небольшое упреждение: на экран строка попадает с задержкой
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= x { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let s = lines[found].text
        return s.isEmpty ? "♪" : s
    }

    func reset() {
        task?.cancel(); task = nil
        token += 1
        currentKey = nil
        state = .idle
        lines = []
    }

    // MARK: - Сеть

    private func fetch(_ track: Track, key: String, token: Int) {
        var items = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        if !track.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }

        request(path: "/api/get", items: items) { [weak self] result in
            guard let self, self.token == token else { return }
            switch result {
            case .success(let data):
                self.finish(key: key, token: token, record: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            case .notFound:
                self.search(track, key: key, token: token)
            case .failure:
                self.finish(key: key, token: token, record: nil, failed: true)
            }
        }
    }

    private func search(_ track: Track, key: String, token: Int) {
        let items = [URLQueryItem(name: "track_name", value: track.title),
                     URLQueryItem(name: "artist_name", value: track.artist)]
        request(path: "/api/search", items: items) { [weak self] result in
            guard let self, self.token == token else { return }
            switch result {
            case .success(let data):
                let all = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                self.finish(key: key, token: token, record: Self.best(of: all, duration: track.duration))
            case .notFound:
                self.finish(key: key, token: token, record: nil)
            case .failure:
                self.finish(key: key, token: token, record: nil, failed: true)
            }
        }
    }

    private enum Reply { case success(Data), notFound, failure }

    private func request(path: String, items: [URLQueryItem], done: @escaping (Reply) -> Void) {
        var c = URLComponents()
        c.scheme = "https"; c.host = "lrclib.net"; c.path = path; c.queryItems = items
        guard let url = c.url else { done(.failure); return }
        let t = session.dataTask(with: url) { data, resp, err in
            let r: Reply
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 { r = .notFound }
            else if let data, err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 { r = .success(data) }
            else { r = .failure }
            DispatchQueue.main.async { done(r) }
        }
        task = t
        t.resume()
    }

    /// Из результатов поиска берём запись с синхронным текстом и самой близкой длительностью.
    private static func best(of records: [[String: Any]], duration: Double) -> [String: Any]? {
        let synced = records.filter { (($0["syncedLyrics"] as? String) ?? "").isEmpty == false }
        guard !synced.isEmpty else { return records.first }
        guard duration > 0 else { return synced.first }
        return synced.min {
            abs((($0["duration"] as? Double) ?? 0) - duration) < abs((($1["duration"] as? Double) ?? 0) - duration)
        }
    }

    // MARK: - Результат

    private func finish(key: String, token: Int, record: [String: Any]?, failed: Bool = false) {
        guard self.token == token else { return }
        let entry: Entry
        if failed {
            entry = Entry(state: .failed, lines: [])
        } else if let lrc = record?["syncedLyrics"] as? String, !lrc.isEmpty {
            let parsed = Self.parse(lrc)
            entry = parsed.isEmpty ? Entry(state: .noSync, lines: []) : Entry(state: .ready, lines: parsed)
        } else if record != nil {
            entry = Entry(state: .noSync, lines: [])   // запись есть, но без таймкодов (или инструментал)
        } else {
            entry = Entry(state: .notFound, lines: [])
        }
        // Сетевые сбои не кэшируем — при следующем открытии попробуем снова.
        if entry.state != .failed { remember(key, entry) } else { currentKey = nil }
        state = entry.state
        lines = entry.lines
    }

    private func remember(_ key: String, _ entry: Entry) {
        cache[key] = entry
        order.append(key)
        if order.count > cacheLimit { cache[order.removeFirst()] = nil }
    }

    // MARK: - Разбор LRC

    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)

    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        lrc.enumerateLines { raw, _ in
            let line = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: line.length))
            guard let last = matches.last else { return }
            let text = line.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let mins = Double(line.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(line.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = line.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                out.append(LyricLine(time: mins * 60 + sec + frac, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
