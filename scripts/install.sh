#!/bin/sh
# Build NoteAnywhere.app into ~/Applications and launch it. On launch the app registers itself as the native
# messaging host of every installed Chromium browser (BrowserBridge.swift), so the extension can reach it.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
APP="$HOME/Applications/NoteAnywhere.app"
pkill -x MemoryNotes || true
# Called MemoryNotes.app before the rename. Same bundle id and certificate, so the Accessibility permission carries over.
rm -rf "$HOME/Applications/MemoryNotes.app"
scripts/make_app.sh .build/release/MemoryNotes "$APP"

# macOS ties the Accessibility permission to the signature. An ad-hoc signature changes with every build, so each
# reinstall would look like a new app and ask again; a real certificate keeps it. Override with MEMORYNOTES_SIGN_ID.
# The choice is remembered in .signing-identity (untracked): with several certificates, keychain order can change.
SIGN_ID=${MEMORYNOTES_SIGN_ID:-$(cat .signing-identity 2>/dev/null || true)}
# Otherwise an Apple Development certificate of the personal team only: this Mac also holds work teams' certificates.
TEAM=${MEMORYNOTES_TEAM_ID:-GH5YVSN865}
[ -n "$SIGN_ID" ] || SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' |
  while read -r name; do
    if security find-certificate -c "$name" -p | openssl x509 -noout -subject | grep -Eq "OU ?= ?$TEAM([,/]|$)"; then
      echo "$name"
      break
    fi
  done)
[ -z "$SIGN_ID" ] || [ -f .signing-identity ] || printf '%s\n' "$SIGN_ID" > .signing-identity
if [ -z "$SIGN_ID" ]; then
  echo "No Apple Development certificate of team $TEAM: signing ad-hoc, so Accessibility must be re-allowed after each install."
  SIGN_ID=-
fi
codesign --force --sign "$SIGN_ID" "$APP"

open "$APP"
echo "Installed $APP. Now load $(pwd)/extension as an unpacked extension."
