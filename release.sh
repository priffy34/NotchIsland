#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?Использование: ./release.sh 1.1}"

# версия в Info.plist
sed -i '' "s|<key>CFBundleShortVersionString</key><string>.*</string>|<key>CFBundleShortVersionString</key><string>$V</string>|" Info.plist

./build.sh
ditto -c -k --keepParent NotchIsland.app "NotchIsland-$V.zip"

git add -A
git diff --cached --quiet || git commit -m "Release v$V"
git push

gh release create "v$V" "NotchIsland-$V.zip" --title "NotchIsland $V" --generate-notes
