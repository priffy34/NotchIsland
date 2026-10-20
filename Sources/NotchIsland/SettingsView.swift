import AppKit
import SwiftUI

/// Окно настроек (открывается из меню «⋯» → «Настройки…» или по ⌘,).
final class SettingsWindow {
    private var window: NSWindow?

    func show(settings: AppSettings) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings))
            let w = NSWindow(contentViewController: host)
            w.title = "Настройки Notch Island"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 440, height: 700))
            w.center()
            window = w
        }
        // Приложение без иконки в Dock: окно нужно активировать вручную.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    private func title(_ tab: IslandTab) -> String {
        switch tab {
        case .music: return "Музыка"
        case .timer: return "Таймер"
        case .shelf: return "Полка"
        case .clipboard: return "Буфер обмена"
        }
    }

    var body: some View {
        Form {
            Section("Размер острова") {
                Picker("Размер", selection: $settings.size) {
                    ForEach(IslandSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Вкладка по умолчанию") {
                Picker("Открывать на", selection: $settings.defaultTab) {
                    Text("Последней использованной").tag(-1)
                    ForEach(IslandTab.allCases.filter { settings.isEnabled($0) }, id: \.rawValue) { tab in
                        Text(title(tab)).tag(tab.rawValue)
                    }
                }
            }

            Section("Цвета") {
                Toggle("Акцент из обложки трека", isOn: $settings.accentFromArtwork)
                ColorPicker("Свой цвет акцента", selection: Binding(
                    get: { settings.customAccent }, set: { settings.customAccent = $0 }))
                    .disabled(settings.accentFromArtwork)
                ColorPicker("Цвет таймера", selection: Binding(
                    get: { settings.timerColor }, set: { settings.timerColor = $0 }))
            }

            Section("Модули") {
                Toggle("Музыка", isOn: $settings.musicOn)
                Toggle("Только музыка (без YouTube и видео)", isOn: $settings.musicOnly)
                    .disabled(!settings.musicOn)
                Toggle("Тексты песен (LRCLIB)", isOn: $settings.lyricsOn)
                    .disabled(!settings.musicOn)
                Toggle("Таймер и секундомер", isOn: $settings.timerOn)
                Toggle("Полка для файлов", isOn: $settings.shelfOn)
                Toggle("История буфера обмена", isOn: $settings.clipboardOn)
                Toggle("Превью скриншота", isOn: $settings.screenshotOn)
                Toggle("Зарядка (батарея)", isOn: $settings.batteryOn)
                Toggle("Bluetooth-устройства", isOn: $settings.bluetoothOn)
            }

            Section {
                Toggle("Переводчик выделенного текста", isOn: $settings.translatorOn)
                Picker("Сочетание клавиш", selection: $settings.hotkey) {
                    ForEach(HotkeyPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(!settings.translatorOn)
                Toggle("Переводить через Claude (качественнее, нужен ключ)", isOn: $settings.translateViaClaude)
                    .disabled(!settings.translatorOn)
                SecureField("Ключ Anthropic API (sk-ant-…)", text: $settings.apiKey)
                    .disabled(!settings.translatorOn)
            } header: {
                Text("Переводчик")
            } footer: {
                Text("Выделите текст и нажмите сочетание: перевод появится у выреза. Для чтения выделения нужен доступ «Универсальный доступ». Без ключа работает бесплатный MyMemory (≈5000 символов в день); режимы «Объяснить» и «Исправить» требуют ключ. Выделенный текст отправляется на сервер выбранного сервиса. Ключ хранится в связке ключей.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if settings.clipboardOn {
                Section {
                    Toggle("Вставлять сразу в активное приложение", isOn: $settings.autoPaste)
                        .onChange(of: settings.autoPaste) { on in
                            if on { ClipboardManager.requestAccessibility() }
                        }
                } header: {
                    Text("Буфер обмена")
                } footer: {
                    Text("Без этого клик возвращает запись в буфер, а вставить нужно самому (⌘V). Для автовставки macOS попросит доступ «Универсальный доступ». История хранится только в памяти и стирается при выходе.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 700)
    }
}
