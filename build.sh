#!/bin/bash
# Сборка NotchIsland.app. Нужны Xcode Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="NotchIsland.app"
rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Сборка адаптера Now Playing…"
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 \
  -framework Foundation -o build/libmradapter.dylib Adapter/adapter.m
codesign -f -s - build/libmradapter.dylib

echo "→ Сборка приложения…"
swift build -c release

cp .build/release/NotchIsland "$APP/Contents/MacOS/NotchIsland"
cp build/libmradapter.dylib Adapter/mediaremote.pl "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"

echo "✓ Готово: $(pwd)/$APP"
echo "  Запуск: open $APP   (можно перенести в /Applications)"
