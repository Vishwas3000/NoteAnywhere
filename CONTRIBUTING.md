# Contributing to NoteAnywhere

This repo is NoteAnywhere's apps:

- the Mac app (`Sources/`),
- the iPhone app (`ios/`),
- the Android app (`android/`),
- the Chrome/Brave extension (`extension/`),
- and the editor they share (`editor/`).

The website isn't in this repo. If something on noteanywhere.app is wrong, open an issue here.

Thanks for helping. Bug reports, small fixes and ideas are all welcome. For anything bigger, open an issue first, so
we can agree on the approach before you spend time on it.

## Pull requests

`main` is what ships, and it changes only through pull requests.

1. Fork the repo and make a branch from `main`.
2. Make your change, with a test for any new logic. Run the tests for the parts you touched (below).
3. Open a pull request to `main`. Say what you changed, why, and how you tested it. Screenshots help for UI changes.
4. The maintainer reviews it, then merges it or asks for changes.

Pull requests that touch release or signing code get a closer look, because that code runs when a release is built.
That means `scripts/release.sh`, `scripts/make_app.sh`, `.github/` and entitlements, and the update feed and key in
`Info.plist` (`SUFeedURL`, `SUPublicEDKey`), which decide what installed copies accept as an update.

## Releases

Only the maintainer builds, signs, notarizes and publishes releases:

- the Mac DMG, signed with the maintainer's Developer ID;
- the Chrome Web Store extension;
- later, the phone apps.

A merged pull request ships in the next release. You don't need to change `VERSION`.

## Build

### Mac app and extension

You need macOS 15+, Xcode 26 (or its command-line tools) and Node.js 20.19+ or 22.12+.

```sh
./scripts/install.sh
```

This builds the app into `~/Applications`, builds the shared editor (`editor/`), and registers the native messaging
host for Chrome and Brave. Then load `extension/` as an unpacked extension (Developer mode ▸ Load unpacked).

To try things without touching your own notes, point the app at another folder:

```sh
MEMORYNOTES_DIR=/tmp/notes-dev ~/Applications/NoteAnywhere.app/Contents/MacOS/MemoryNotes
```

The browser host is started by Chrome without that variable, so it still uses your real database.

### iPhone app

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is
generated, not committed:

```sh
cd ios && xcodegen generate
xcodebuild -project MemoryNotes.xcodeproj -scheme MemoryNotes -destination 'generic/platform=iOS Simulator' build
```

Or open `ios/MemoryNotes.xcodeproj` in Xcode and run it on a simulator. To run it on your own iPhone, set your team in
`DEVELOPMENT_TEAM` in `ios/project.yml` on your machine, and leave that change out of your pull request.

### Android app

You need JDK 17 and the Android SDK (`ANDROID_HOME`, or `sdk.dir` in `android/local.properties`).

```sh
cd android && ./gradlew assembleDebug
```

## Test

```sh
swift test                                  # Swift: parsers, dates, tags, graph, sync store, screen geometry
swift build -c release && python3 scripts/test_host.py   # the native messaging host, end to end
cd editor && npm test                       # the shared editor (happy-dom)
cd android && ./gradlew testDebugUnitTest   # Android: notes store, sync rows, vault
MN_UI_PROBE=1 swift test --filter sidebarDrag   # main window off-screen: dragging the sidebar keeps panes in the window
```

The iPhone app's UI tests are in `ios/UITests`; run them from Xcode on a simulator.

If you change the editor, run `cd editor && npm run build`. The built files in `editor/dist` and `extension/editor`
are committed, because the extension loads straight from the repo.

## Code style

- Keep it short. The smallest change that fully solves the problem wins; no options or abstractions nobody asked for.
- Comments say why, not what. One line is usually enough.
- Follow the surrounding code: SwiftUI + AppKit, plain SQLite calls in `NoteStore`, vanilla JS in the extension,
  Jetpack Compose on Android.
- Internal names stay `MemoryNotes` / `com.memorynotes.*` (bundle id, host name, URL scheme, data folder) so existing
  installs keep their data. User-visible text says NoteAnywhere.
- New logic comes with a test.
- No keys, passwords or personal data in commits.

## Decisions

Every product or design decision goes in [docs/DECISIONS.md](docs/DECISIONS.md): what was decided, why, what was
rejected, who decided, and its status. If your pull request makes a choice someone could reasonably question, add an
entry.

## License

By contributing you agree that your contribution is licensed under the [GPL-3.0](LICENSE), like the rest of the
project.
