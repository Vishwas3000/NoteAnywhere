# MemoryNotes

Notes that follow what you're looking at. Write a note for an app (Xcode, Slack, Figma…) or a website/page,
and it pops up in a floating overlay whenever that app is in front or that tab is open.

- **macOS app** (SwiftUI): menu-bar icon, a notes window, and a floating panel that follows the frontmost app.
- **Chrome/Brave extension**: in-page overlay for website notes. Notes are saved by the Mac app, so every note lives in one place.

## Install

```sh
./scripts/install.sh
```

This builds `~/Applications/MemoryNotes.app`, launches it, and registers the browser bridge for Chrome and Brave.
Then in `chrome://extensions` (or `brave://extensions`), turn on Developer mode → **Load unpacked** → pick `extension/`.

## Use

- **App notes**: switch to an app that has notes and the overlay opens. For an app with no notes yet, use the menu-bar
  icon → *Show/Hide Overlay* → **+ Note for <App>**.
- **Website notes**: open a site that has notes and the overlay opens. For a site with none, click the extension
  icon (or press ⌥⇧N) → **+ This site** (e.g. `github.com`) or **+ This page** (e.g. `github.com/vercel/next.js`).
  A note matches its target and everything under it.
- **All notes**: menu-bar icon → *Open Notes*. Website notes made in the browser show up here too.

## How it fits together

```
Chrome/Brave tab ──content.js──▶ background.js ──Native Messaging──▶ MemoryNotes binary (host mode)
                                                                         │
                                       ~/Library/Application Support/MemoryNotes/notes/<id>.json
                                                                         │
MemoryNotes.app (watches the folder) ◀───────────────────────────────────┘
```

Chrome starts the same app binary as a short-lived host process, so the extension works even when the app is closed.
Decisions and their reasons are in [docs/DECISIONS.md](docs/DECISIONS.md); the plan is in [docs/ROADMAP.md](docs/ROADMAP.md).

## Test

```sh
swift build -c release && python3 scripts/test_host.py
```
