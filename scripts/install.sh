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

# The shared editor (also used by the browser extension) is built from editor/ and loaded by the app's web views.
(cd editor && npm ci --no-audit --no-fund --silent && npm run build --silent)
mkdir -p "$APP/Contents/Resources/editor"
cp editor/dist/* app/editor.html "$APP/Contents/Resources/editor/"
codesign --force --sign - "$APP"

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
