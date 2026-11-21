#!/bin/sh
# Assembles an unsigned NoteAnywhere.app from a built binary: Info.plist, icon, shared editor, SwiftPM resource bundles.
# Used by install.sh and release.sh. Usage: scripts/make_app.sh <built MemoryNotes binary> <path/to/NoteAnywhere.app>
set -eu
cd "$(dirname "$0")/.."
BIN=$1 APP=$2

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/editor" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/MemoryNotes"
# Sparkle (the updater), found through the binary's @executable_path/../Frameworks rpath (Package.swift). Its XPC
# services are only for sandboxed apps, and Sparkle's docs say others may remove them.
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
cp Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$(cat VERSION)" "$APP/Contents/Info.plist"  # release.sh overrides with a tag
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

# The Safari extension (D82): an app extension that Xcode builds from safari/project.yml, inside the app's PlugIns.
if command -v xcodegen >/dev/null; then
  (cd safari && xcodegen generate --quiet && xcodebuild -project NoteAnywhereSafari.xcodeproj -scheme NoteAnywhereSafari \
    -configuration Release -destination 'generic/platform=macOS' -derivedDataPath ../.build/safari build -quiet)
  PLUGIN=$APP/Contents/PlugIns/NoteAnywhereSafari.appex
  mkdir -p "$APP/Contents/PlugIns"
  ditto .build/safari/Build/Products/Release/NoteAnywhereSafari.appex "$PLUGIN"
  for key in CFBundleShortVersionString CFBundleVersion; do  # release.sh overrides with a tag, as for the app
    plutil -replace $key -string "$(cat VERSION)" "$PLUGIN/Contents/Info.plist"
  done
else
  echo "XcodeGen isn't installed (brew install xcodegen): this build has no Safari extension." >&2
fi
