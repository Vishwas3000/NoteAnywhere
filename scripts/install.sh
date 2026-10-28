#!/bin/sh
# Build MemoryNotes.app into ~/Applications and register it as the native messaging host for Chrome and Brave.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
APP="$HOME/Applications/MemoryNotes.app"
pkill -x MemoryNotes || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MemoryNotes "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

# App icon, drawn by scripts/make_icon.swift.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET" "$APP/Contents/Resources"
swift scripts/make_icon.swift "$ICONSET/icon_512x512@2x.png"
for px in 16 32 128 256 512; do
  sips -z $px $px "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# The shared editor (also used by the browser extension) is built from editor/ and loaded by the app's web views.
(cd editor && npm ci --no-audit --no-fund --silent && npm run build --silent)
mkdir -p "$APP/Contents/Resources/editor"
cp editor/dist/* app/editor.html "$APP/Contents/Resources/editor/"
# macOS ties the Accessibility permission to the signature. An ad-hoc signature changes with every build, so each
# reinstall would look like a new app and ask again; a real certificate keeps it. Override with MEMORYNOTES_SIGN_ID.
# The choice is remembered in .signing-identity (untracked): with several certificates, keychain order can change.
SIGN_ID=${MEMORYNOTES_SIGN_ID:-$(cat .signing-identity 2>/dev/null || true)}
[ -n "$SIGN_ID" ] || SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)
[ -z "$SIGN_ID" ] || [ -f .signing-identity ] || printf '%s\n' "$SIGN_ID" > .signing-identity
if [ -z "$SIGN_ID" ]; then
  echo "No Apple Development certificate: signing ad-hoc, so Accessibility must be re-allowed after each install."
  SIGN_ID=-
fi
codesign --force --sign "$SIGN_ID" "$APP"

# The manifest "key" pins the unpacked extension's id; Chrome's id is the first 32 hex of sha256(key) mapped 0-f -> a-p.
ID=$(python3 -c 'import json; print(json.load(open("extension/manifest.json"))["key"])' \
  | base64 -d | shasum -a 256 | head -c 32 | tr 0-9a-f a-p)

for browser in "Google/Chrome" "BraveSoftware/Brave-Browser"; do
  dir="$HOME/Library/Application Support/$browser"
  [ -d "$dir" ] || continue
  mkdir -p "$dir/NativeMessagingHosts"
  cat > "$dir/NativeMessagingHosts/com.memorynotes.host.json" <<JSON
{
  "name": "com.memorynotes.host",
  "description": "MemoryNotes",
  "path": "$APP/Contents/MacOS/MemoryNotes",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$ID/"]
}
JSON
  echo "Registered native host for $browser"
done

open "$APP"
echo "Installed $APP. Now load $(pwd)/extension as an unpacked extension (extension id $ID)."
