import Foundation
import IOBluetooth

/// Подписка на события подключения/отключения Bluetooth-устройств (без поллинга).
final class BluetoothManager: NSObject, ObservableObject {
    struct Toast: Equatable {
        let name: String
        let icon: String
        let connected: Bool
    }

    @Published private(set) var toast: Toast?

    private var notes: [IOBluetoothUserNotification] = []
    private var startedAt = Date()
    private var token = 0

    func stop() {
        notes.forEach { $0.unregister() }
        notes.removeAll()
        toast = nil
        token += 1
    }

    func start() {
        guard notes.isEmpty else { return }
        startedAt = Date()
        if let n = IOBluetoothDevice.register(forConnectNotifications: self,
                                              selector: #selector(deviceConnected(_:fromDevice:))) {
            notes.append(n)
        }
        // Уже подключённые устройства: вешаем только слушатель отключения.
        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for d in paired where d.isConnected() { watchDisconnect(d) }
        }
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        if let n = device.register(forDisconnectNotification: self,
                                   selector: #selector(deviceDisconnected(_:fromDevice:))) {
            notes.append(n)
        }
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        watchDisconnect(device)
        // Первые секунды после старта игнорируем — система может «переиграть» старые подключения.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        show(device, connected: true)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        show(device, connected: false)
    }

    private func show(_ device: IOBluetoothDevice, connected: Bool) {
        let name = device.name ?? device.addressString ?? "Устройство"
        let icon = Self.icon(for: name, major: device.deviceClassMajor)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.toast = Toast(name: name, icon: icon, connected: connected)
            self.token += 1
            let t = self.token
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, self.token == t else { return }
                self.toast = nil
            }
        }
    }

    private static func icon(for name: String, major: BluetoothDeviceClassMajor) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("keyboard") || n.contains("клавиатур") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("mouse") || n.contains("мышь") { return "computermouse" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return "gamecontroller" }
        if major == 4 { return "headphones" }       // Audio/Video
        if major == 5 { return "keyboard" }         // Peripheral
        return "dot.radiowaves.left.and.right"
    }
}
