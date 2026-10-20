#!/bin/bash
# Сборка NotchIsland.app. Нужны Xcode Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="NotchIsland.app"
# Идентичность подписи. Права «Универсальный доступ» привязываются к подписи приложения: при обычной ad-hoc подписи
# она меняется в каждой сборке, и система перестаёт узнавать уже выданный доступ. Поэтому:
#   • SIGN_IDENTITY="Имя сертификата" ./build.sh — подпись своим сертификатом (лучший вариант, см. README);
#   • без переменной — ad-hoc с фиксированным требованием по bundle id, права переживают обновления.
IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)"
rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Сборка адаптера Now Playing…"
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 \
  -framework Foundation -o build/libmradapter.dylib Adapter/adapter.m
codesign -f -s "$IDENTITY" build/libmradapter.dylib

echo "→ Сборка приложения…"
swift build -c release

cp .build/release/NotchIsland "$APP/Contents/MacOS/NotchIsland"
cp build/libmradapter.dylib Adapter/mediaremote.pl "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep -s - -r "=designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --deep -s "$IDENTITY" "$APP"
fi

echo "✓ Готово: $(pwd)/$APP"
echo "  Запуск: open $APP   (можно перенести в /Applications)"
