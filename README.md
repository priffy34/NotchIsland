# NotchIsland

Динамический остров для MacBook с вырезом: музыка, буфер обмена, полка файлов,
переводчик и не только.

![скриншот](docs/screenshot.png)

## Возможности
- Музыка: обложка, текст песни, управление и перемотка
- Буфер обмена и полка файлов
- Переводчик выделенного текста
- Превью скриншотов, уведомления о Bluetooth и зарядке

## Установка
1. Скачай `NotchIsland-x.y.zip` из [Releases](../../releases/latest).
2. Распакуй и перенеси `NotchIsland.app` в `/Applications`.
3. Приложение не нотаризовано, поэтому при первом запуске:
   правый клик → Открыть, либо `xattr -cr /Applications/NotchIsland.app`.

## Сборка из исходников
Нужны Xcode Command Line Tools (`xcode-select --install`):

    ./build.sh

## Требования и ограничения
- macOS 13+, Apple Silicon
- Для «Now Playing» используется приватный MediaRemote API,
  поэтому в App Store приложение попасть не может

## Лицензия
MIT
