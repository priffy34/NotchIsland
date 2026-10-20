import AppKit
import ImageIO

struct Shot: Identifiable {
    let id = UUID()
    let url: URL
    let image: NSImage
}

/// Следит за новыми скриншотами через Spotlight (`NSMetadataQuery`) — по событиям, без поллинга и обхода папок.
///
/// • Ищем по атрибуту `kMDItemIsScreenCapture`, его ставит сама система, поэтому работает и с ⌘⇧3/4/5, и с нестандартными именами.
/// • Область поиска — только папка, куда сохраняются скриншоты (`com.apple.screencapture location`, по умолчанию Рабочий стол).
///   Так запрос не тащит в память все скриншоты из домашней папки.
/// • Результат первичной выборки игнорируем, реагируем только на добавленные позже и свежие (< 20 с) файлы.
/// • Миниатюра строится через ImageIO в фоне и не больше 360 px — большой PNG целиком в память не читается.
final class ScreenshotManager: NSObject, ObservableObject {
    @Published private(set) var latest: Shot?

    /// Вызывается на главном потоке, когда миниатюра готова.
    var onShot: (() -> Void)?

    private var query: NSMetadataQuery?
    private var gathered = false
    private var handled: [String] = []
    private let queue = DispatchQueue(label: "notchisland.shots", qos: .utility)

    func start() {
        guard query == nil else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "%K == 1", "kMDItemIsScreenCapture")
        q.searchScopes = [Self.screenshotFolder()]
        q.notificationBatchingInterval = 0.3

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didGather(_:)), name: .NSMetadataQueryDidFinishGathering, object: q)
        nc.addObserver(self, selector: #selector(didUpdate(_:)), name: .NSMetadataQueryDidUpdate, object: q)
        gathered = false
        query = q
        q.start()
    }

    func stop() {
        guard let q = query else { return }
        q.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        query = nil
        latest = nil
    }

    func dismiss() { latest = nil }

    // MARK: - События

    @objc private func didGather(_ n: Notification) {
        gathered = true      // всё, что уже лежало в папке, — не новость
    }

    @objc private func didUpdate(_ n: Notification) {
        guard gathered,
              let added = n.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] else { return }
        for item in added {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !handled.contains(path) else { continue }
            let created = (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date) ?? .distantPast
            guard abs(created.timeIntervalSinceNow) < 20 else { continue }
            handled.append(path)
            if handled.count > 20 { handled.removeFirst() }
            makeThumbnail(URL(fileURLWithPath: path), attempt: 0)
        }
    }

    // MARK: - Миниатюра

    private func makeThumbnail(_ url: URL, attempt: Int) {
        queue.async { [weak self] in
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                // Файл мог быть ещё не дописан — пробуем ещё пару раз.
                if attempt < 3 {
                    self?.queue.asyncAfter(deadline: .now() + 0.4) { self?.makeThumbnail(url, attempt: attempt + 1) }
                }
                return
            }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            DispatchQueue.main.async {
                guard let self, self.query != nil else { return }
                self.latest = Shot(url: url, image: image)
                self.onShot?()
            }
        }
    }

    // MARK: - Папка скриншотов

    private static func screenshotFolder() -> URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (loc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop", isDirectory: true)
    }
}
