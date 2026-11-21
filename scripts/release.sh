#!/bin/sh
# Builds dist/NoteAnywhere-<version>.dmg (Developer ID signed, notarized, stapled), the Chrome Web Store zip
# dist/NoteAnywhere-extension-<version>.zip and the Firefox add-on zip dist/NoteAnywhere-firefox-<version>.zip.
# Run by the maintainer, who publishes releases.
# Usage: scripts/release.sh [--skip-notarize]
#   NOTEANYWHERE_SIGN_ID  signing identity (default: the Developer ID below, by SHA-1)
#   NOTEANYWHERE_TEAM_ID  team the signature must belong to (default GH5YVSN865)
#   NOTARY_PROFILE        notarytool keychain profile (default NoteAnywhere)
set -eu
cd "$(dirname "$0")/.."

case ${1:-} in
  "") NOTARIZE=1 ;;
  --skip-notarize) NOTARIZE= ;;
  *) echo "usage: $0 [--skip-notarize]" >&2; exit 2 ;;
esac
# Two certificates are named "Developer ID Application: Vishwas Prakash (GH5YVSN865)"; the SHA-1 picks one.
SIGN_ID=${NOTEANYWHERE_SIGN_ID:-598A3CFA4889E9D4A2E865815A4328A30EEC1744}
TEAM=${NOTEANYWHERE_TEAM_ID:-GH5YVSN865}
NOTARY_PROFILE=${NOTARY_PROFILE:-NoteAnywhere}

# A vX.Y.Z tag on HEAD wins, else the VERSION file. Used for the app, the DMG and the extension alike.
VERSION=$(git describe --tags --exact-match --match 'v*' 2>/dev/null | sed 's/^v//' || true)
[ -n "$VERSION" ] || VERSION=$(cat VERSION)
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Version must be X.Y.Z, got '$VERSION'" >&2; exit 1; }
# Sparkle installs only updates signed with this key's private half, which generate_keys keeps in the maintainer's
# keychain (D75). A placeholder would ship an app that can never update.
plutil -extract SUPublicEDKey raw Info.plist | grep -Eqx '[A-Za-z0-9+/]{43}=' ||
  { echo "Info.plist: SUPublicEDKey is not a real key; paste the public key that Sparkle's generate_keys prints" >&2; exit 1; }

notarize() {  # notarize + staple one .zip/.dmg; stapler fails if Apple didn't accept it
  xcrun notarytool submit "$1" --wait --keychain-profile "$NOTARY_PROFILE"
  xcrun stapler staple "${2:-$1}"
}

DIST=dist APP=dist/NoteAnywhere.app
DMG=$DIST/NoteAnywhere-$VERSION.dmg ZIP=$DIST/NoteAnywhere-extension-$VERSION.zip FIREFOX_ZIP=$DIST/NoteAnywhere-firefox-$VERSION.zip
rm -rf "$DIST"
mkdir -p "$DIST"

# App: universal (Apple silicon + Intel). Building through XCBuild also makes Bundle.module look in Contents/Resources.
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
scripts/make_app.sh "$(swift build -c release $ARCHS --show-bin-path)/MemoryNotes" "$APP"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
PLUGIN=$APP/Contents/PlugIns/NoteAnywhereSafari.appex
[ -d "$PLUGIN" ] || { echo "No Safari extension in the app: install XcodeGen (brew install xcodegen)" >&2; exit 1; }
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLUGIN/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$PLUGIN/Contents/Info.plist"

# The app: hardened runtime, no entitlements: no sandbox, JIT, unsigned libraries or Apple Events. WebKit's JIT runs in its own
# processes; Accessibility, the Keychain (file-based) and Foundation Models need none.
# Inside out, in the order Sparkle documents for signing outside Xcode (never --deep): its helpers, the framework, the app.
FW=$APP/Contents/Frameworks/Sparkle.framework
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$code"
done
# The Safari extension runs sandboxed: it alone has entitlements (safari/NoteAnywhereSafari.entitlements, D82).
codesign --force --options runtime --timestamp --entitlements safari/NoteAnywhereSafari.entitlements --sign "$SIGN_ID" "$PLUGIN"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -qx "TeamIdentifier=$TEAM" || { echo "Signed by a team other than $TEAM" >&2; exit 1; }
if [ -n "$NOTARIZE" ]; then
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  notarize "$DIST/notarize.zip" "$APP"
  rm "$DIST/notarize.zip"
fi
# Unnotarized builds are rejected here, which --skip-notarize expects.
spctl -a -vv -t exec "$APP" || [ -z "$NOTARIZE" ]

# DMG: the app next to an /Applications link, to drag it across.
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/NoteAnywhere.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname NoteAnywhere -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
if [ -n "$NOTARIZE" ]; then notarize "$DMG"; fi
spctl -a -vv -t open --context context:primary-signature "$DMG" || [ -z "$NOTARIZE" ]

# The extension for the Chrome Web Store and for Firefox's add-ons site: runtime files only, each manifest with just
# the keys its browser reads. Neither has "key": the Web Store assigns the id and rejects it, Firefox goes by gecko.id.
for BROWSER in chrome firefox; do
  EXT=$(mktemp -d)
  cp -R extension/background.js extension/content.js extension/overlay.html extension/overlay.js extension/editor \
    extension/icons "$EXT/"
  python3 - "$BROWSER" "$VERSION" extension/manifest.json "$EXT/manifest.json" <<'PY'
import json, sys
browser, version, src, dst = sys.argv[1:]
manifest = json.load(open(src))
del manifest["key"]
manifest["version"] = version
if browser == "chrome":
    del manifest["browser_specific_settings"], manifest["background"]["scripts"]
else:  # Firefox runs background.js as an event page: it has no extension service workers
    del manifest["background"]["service_worker"]
json.dump(manifest, open(dst, "w"), indent=2)
PY
  if [ "$BROWSER" = chrome ]; then OUT=$ZIP; else OUT=$FIREFOX_ZIP; fi
  (cd "$EXT" && zip -qrX - .) > "$OUT"
done

echo "Built $DMG, $ZIP and $FIREFOX_ZIP (version $VERSION)${NOTARIZE:+, notarized}."
