#!/bin/sh
# Assembles an unsigned NoteAnywhere.app from a built binary: Info.plist, icon, shared editor, SwiftPM resource bundles.
# Used by install.sh and release.sh. Usage: scripts/make_app.sh <built MemoryNotes binary> <path/to/NoteAnywhere.app>
set -eu
cd "$(dirname "$0")/.."
BIN=$1 APP=$2

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/editor"
cp "$BIN" "$APP/Contents/MacOS/MemoryNotes"
cp Info.plist "$APP/Contents/"
# Dependencies' resources (swift-transformers' fallback tokenizer configs); Bundle.module looks in Contents/Resources.
for bundle in "$(dirname "$BIN")"/*.bundle; do [ ! -d "$bundle" ] || cp -R "$bundle" "$APP/Contents/Resources/"; done

# App icon, drawn by scripts/make_icon.swift.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$ICONSET/icon_512x512@2x.png"
for px in 16 32 128 256 512; do
  sips -z $px $px "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# The shared editor (also used by the browser extension, which the build refreshes) is loaded by the app's web views.
(cd editor && npm ci --no-audit --no-fund --silent && npm run build --silent)
cp editor/dist/* app/editor.html "$APP/Contents/Resources/editor/"
