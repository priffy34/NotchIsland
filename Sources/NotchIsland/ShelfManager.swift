import AppKit

struct ShelfItem: Identifiable {
    let id = UUID()
    let url: URL
    let icon: NSImage
}

/// Полка: хранит только ссылки на файлы (ничего не копирует), список переживает перезапуск.
final class ShelfManager: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    private let key = "shelfPaths"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { Self.makeItem(URL(fileURLWithPath: $0)) }
    }

    private static func makeItem(_ url: URL) -> ShelfItem {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 48, height: 48)
        return ShelfItem(url: url, icon: icon)
    }

    func add(_ url: URL) {
        guard url.isFileURL, !items.contains(where: { $0.url == url }) else { return }
        items.insert(Self.makeItem(url), at: 0)
        save()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func airDrop() {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    private func save() {
        UserDefaults.standard.set(items.map { $0.url.path }, forKey: key)
    }
}
