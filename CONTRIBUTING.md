# Contributing to NoteAnywhere

Thanks for helping. Bug reports, small fixes and ideas are all welcome; for anything bigger, open an issue first so we
can agree on the approach before you spend time on it.

## Build

You need macOS 15+, Xcode 26 (or its command-line tools) and Node.js 20.19+ or 22.12+.

```sh
./scripts/install.sh
```

This builds the app into `~/Applications`, builds the shared editor (`editor/`), and registers the native messaging
host for Chrome and Brave. Then load `extension/` as an unpacked extension (Developer mode ▸ Load unpacked).

To try things without touching your own notes, point the app at another folder:

```sh
MEMORYNOTES_DIR=/tmp/notes-dev ~/Applications/MemoryNotes.app/Contents/MacOS/MemoryNotes
```

The browser host is started by Chrome without that variable, so it still uses your real database.

## Test

```sh
swift test                                  # Swift: parsers, dates, tags, graph, sync store, screen geometry
swift build -c release && python3 scripts/test_host.py   # the native messaging host, end to end
cd editor && npm test                       # the shared editor (happy-dom)
```

If you change the editor, run `cd editor && npm run build`: the built files in `editor/dist` and `extension/editor`
are committed, because the extension loads straight from the repo.

## Code style

- Keep it short. The smallest change that fully solves the problem wins; no options or abstractions nobody asked for.
- Comments say why, not what. One line is usually enough.
- Follow the surrounding code: SwiftUI + AppKit, plain SQLite calls in `NoteStore`, vanilla JS in the extension.
- Internal names stay `MemoryNotes` / `com.memorynotes.*` (bundle id, host name, URL scheme, data folder) so existing
  installs keep their data. User-visible text says NoteAnywhere.
- New logic comes with a test.

## Decisions

Every product or design decision goes in [docs/DECISIONS.md](docs/DECISIONS.md): what was decided, why, what was
rejected, who decided, and its status. If your pull request makes a choice someone could reasonably question, add an
entry.

## License

By contributing you agree that your contribution is licensed under the [GPL-3.0](LICENSE), like the rest of the
project.
