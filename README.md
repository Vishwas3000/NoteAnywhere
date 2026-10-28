# NoteAnywhere

Notes that follow what you're looking at. Write a note for an app (Xcode, Slack, Figma…) or a website/page,
and it pops up in a floating overlay whenever that app is in front or that tab is open.

- **macOS app** (SwiftUI): menu-bar icon, a notes window, and a floating panel that follows the frontmost app.
- **Chrome/Brave extension**: in-page overlay for website notes. Notes are saved by the Mac app, so every note lives in one place.

## Install

- **Mac app** (macOS 15+): download the DMG from [Releases](https://github.com/Vishwas3000/NoteAnywhere/releases/latest),
  drag NoteAnywhere to Applications and open it once. Opening it connects it to Chrome, Brave, Edge, Arc, Vivaldi and Chromium.
- **Browser extension**: from the Chrome Web Store (works in any Chromium browser).

### From source

```sh
./scripts/install.sh
```

This builds `~/Applications/NoteAnywhere.app` and launches it. Then in `chrome://extensions` (or `brave://extensions`),
turn on Developer mode → **Load unpacked** → pick `extension/`. Releases are cut with `scripts/release.sh`; see
[docs/RELEASING.md](docs/RELEASING.md).

## Use

- **App notes**: switch to an app that has notes and the overlay opens. For an app with no notes yet, use the menu-bar
  icon → *Show/Hide Overlay* → **+ Note for <App>**.
- **Website notes**: open a site that has notes and the overlay opens. For a site with none, click the extension
  icon (or press ⌥⇧N) → **+ This site** (e.g. `github.com`) or **+ This page** (e.g. `github.com/vercel/next.js`).
  A note matches its target and everything under it.
- **All notes**: menu-bar icon → *Open Notes*. Website notes made in the browser show up here too.

## How it fits together

```
Chrome/Brave tab ──content.js──▶ background.js ──Native Messaging──▶ NoteAnywhere binary (host mode)
                                                                           │
                                          ~/Library/Application Support/MemoryNotes/memorynotes.sqlite (WAL)
                                                                           │
NoteAnywhere.app (notified on every save) ◀────────────────────────────────┘
```

Chrome starts the same app binary as a short-lived host process, so the extension works even when the app is closed.
Decisions and their reasons are in [docs/DECISIONS.md](docs/DECISIONS.md); the plan is in [docs/ROADMAP.md](docs/ROADMAP.md).

## Test

```sh
swift test && swift build -c release && python3 scripts/test_host.py && (cd editor && npm test)
```

## License

[GPL-3.0](LICENSE).
