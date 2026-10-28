# NoteAnywhere

Notes that show up where they belong: in the app, chat, project or web page they're about.

**[Download for Mac](https://github.com/Vishwas3000/NoteAnywhere/releases/latest)** ·
**[Get the Chrome extension]({{CHROME_WEB_STORE_URL}})** · Free and open source (GPL-3.0)

![NoteAnywhere: notes for a Slack channel in the floating panel, next to the main window]({{HERO_SCREENSHOT_URL}})

Write a note while you're in a Slack DM, a VS Code project, a WhatsApp chat or on a GitHub page. Next time you're
back there, the note is waiting in a small floating panel. Everything is also in one Apple Notes–style window, with
on-device semantic search, a calendar, #tags and a knowledge graph.

Your notes stay on your Mac in a SQLite database. Search and the AI actions run on-device. Sync is optional and off
by default.

## Features

- **Notes for the app and window you're in.** NoteAnywhere reads the front window's title to know the Slack
  workspace and channel or DM, the VS Code project and file, the Xcode project, the WhatsApp chat, and so on. A broader
  place sees the notes of the places under it: Slack › Acme shows the notes of all its channels.
- **Notes for web pages.** A Chrome/Brave extension shows a page's notes in a panel on the page. A page also sees the
  notes of its sub-pages: `github.com` lists the notes you wrote on `github.com/apple/swift`.
- **A floating panel that comes and goes.** It opens by itself when the app or chat in front has notes, and ⌥⇧M shows
  or hides it anywhere. It doesn't take focus from the app you're working in, and works over full-screen apps.
- **Live between app and browser.** Edit a website note in the Mac app and the open tab updates, and the other way
  round.
- **Semantic search, on-device.** ⌥⇧Space opens a search box from anywhere. It finds notes by meaning (the
  all-MiniLM-L6-v2 model, running locally) and by exact words. `#tag` lists every note with that tag.
- **Apple Intelligence.** The ✨ menu fixes spelling and grammar, makes text clearer or shorter, turns it into a
  checklist or adds a title, using Apple's on-device model (macOS 26). System Writing Tools work in the editor too.
- **Plain notes too.** A note doesn't need an app or website: ⌘N writes a plain note, ⇧⌘N a website note, and any
  note can gain or lose its website later (Add Website / Remove Website).
- **#tags, Obsidian-style.** Type `#tag` anywhere and nest with `#area/topic`. ⌘-click a tag or search `#tag` to see
  its notes; the sidebar lists every tag with its count.
- **A knowledge graph.** Each note is a dot joined to its app or site, the notes it links to, its #tags (a hub per
  tag), and notes with a similar meaning. Drag, zoom, and switch each kind of link on or off.
- **Dates and tasks.** Type `@` for a Notion-style date menu (Today, Tomorrow, the coming week, Pick a date…), or
  `@today` / `@fri` + Space, or pick a day from 📅 in the toolbar. Dated lines show as chips; ⌘-click one to open that
  day.
- **A calendar.** Month, week and day views. Dated lines and checklist tasks appear under "Planned", with a circle that
  ticks the task in the note itself. Below them, what you edited that day, with each note as it was then.
- **A real Markdown editor**, shared by the app and the extension: headings, lists that continue, checklists,
  tables, code, quotes and links between notes. A Notion-style ⋮⋮ handle drags any block or list item between
  blocks, and ⌘⇧↑/↓ moves the current one.
- **Apple Notes–style design**: a sidebar grouped by Today, Yesterday, Previous 7 Days and so on, and a menu-bar icon.
- **Optional sync** through Supabase, signing in with a link sent to your email.
- **Light on your Mac**: about 0% CPU when idle and 37–65 MB of memory (measured).

## Install

Requires macOS 15 or later, and Chrome or Brave for website notes. The ✨ actions need macOS 26 and a Mac that
supports Apple Intelligence.

1. Download the DMG from [Releases](https://github.com/Vishwas3000/NoteAnywhere/releases/latest), drag NoteAnywhere
   to Applications and open it. It lives in the menu bar.
2. Allow **Accessibility** when asked (System Settings ▸ Privacy & Security ▸ Accessibility). This lets NoteAnywhere
   read window titles so notes can follow the channel or file you're in. Without it, notes are per app.
3. For website notes, add the extension from the [Chrome Web Store]({{CHROME_WEB_STORE_URL}}) (works in Brave too).

The first search downloads the search model once (about 87 MB). Until then, search matches exact words.

## Use

- **App notes.** Switch to an app, chat or project that has notes and the panel opens. For one without notes yet,
  press ⌥⇧M (or use the menu-bar icon) and click **+**.
- **Website notes.** Open a page that has notes and the panel opens on it. For a page without notes, click the
  extension's icon or press ⌥⇧N, then **New note**. Notes written on sub-pages show with a ↳ link to their page.
- **Everything.** Menu-bar icon ▸ Open Notes shows all notes, the calendar (⌘2) and the graph (⌘3). ⌘N makes a
  note that isn't tied to any app or page.

## Keyboard shortcuts

| Keys | Action |
|------|--------|
| ⌥⇧Space | Search all notes, from anywhere |
| ⌥⇧M | Show or hide the notes for the app (and channel or file) in front |
| ⌥⇧N | In Chrome/Brave: show or hide the page's notes |
| ⌘N / ⇧⌘N | New note / new note for a website |
| ⌘F | Find notes |
| ⌘1 / ⌘2 / ⌘3 | Notes / Calendar / Graph |
| ⌘← / ⌘T / ⌘→ | Calendar: previous / today / next |
| ⌘⌫ | Delete the selected note (asks first) |
| ⌘⇧↑ / ⌘⇧↓ | Move the current block or list item |
| ⌘⇧9 | Checklist |
| `@` | Date menu: Today, Tomorrow, the coming week, Pick a date… |
| `@today`, `@fri` + Space | Put this line on a day in the calendar |
| ⌘-click a #tag or date | Show that tag's notes, or that day |
| ⇧⌘/ | All shortcuts, including every editor shortcut and Markdown trigger |

## Privacy

- Notes are stored in `~/Library/Application Support/MemoryNotes/memorynotes.sqlite` on your Mac.
- Search (MiniLM) and the ✨ actions (Apple Foundation Models) run on your Mac.
- The Accessibility permission is used to read the front window's title, and for WhatsApp, the open chat's name from
  its header. Never message contents, keystrokes or the screen.
- The extension asks the app on your Mac whether the current page has notes. It sends nothing to any server.
- Network: site icons from the sites themselves, the search model from Hugging Face once, and Supabase only if you
  turn sync on. No analytics.

Details in [PRIVACY.md](PRIVACY.md).

## How context detection works

When the front app or its window title changes, NoteAnywhere reads the title through the Accessibility API (it
subscribes to change notifications; it doesn't poll) and turns it into a path from broad to narrow:

```
"Sam (DM) - Acme - 8 new items - Slack"        →  Slack › Acme › Sam (DM)
"index.ts — weather-app — Visual Studio Code"  →  Visual Studio Code › weather-app › index.ts
```

It splits on ` - `, ` — `, ` – ` and ` | `, uses the app's own name to tell which end is the broad one, and drops
what changes without the place changing: unread counts, "8 new items", unsaved-file dots. There is no per-app title
parser; the same rules work for every app. The note's target becomes `bundle.id/Acme/Sam (DM)`, so, as with web
pages, a parent place sees its children's notes.

A few apps don't put the place in the title: WhatsApp's is just "WhatsApp". For those, a small table names the
accessibility element that shows the open chat (WhatsApp's header), and only that element is read, once a second
while the app is in front.

Limits: titles carry names, not ids, so renaming a channel starts a new place. The parser lives in
`Sources/MemoryNotes/WindowContext.swift` and is covered by `swift test`.

## Build from source

You need Xcode 26 (or its command-line tools) and Node.js 20.19+ or 22.12+.

```sh
./scripts/install.sh
```

This builds the app into `~/Applications`, launches it, and registers the browser bridge (native messaging host) for
Chrome and Brave. It signs with your first Apple Development certificate if you have one, so the Accessibility
permission survives rebuilds; otherwise it signs ad hoc and macOS asks again after each install. Set
`MEMORYNOTES_SIGN_ID` to pick a certificate.

Then in `chrome://extensions` (or `brave://extensions`), turn on Developer mode, click **Load unpacked** and pick
`extension/`. The manifest's `key` keeps the unpacked extension's id stable, so the bridge recognises it.

Tests:

```sh
swift test && swift build -c release && python3 scripts/test_host.py && (cd editor && npm test)
```

## Architecture

```
Chrome/Brave tab ─content.js─▶ overlay.html (extension iframe) ─Native Messaging─▶ NoteAnywhere binary (host mode)
                                                                                         │
                                     ~/Library/Application Support/MemoryNotes/memorynotes.sqlite (WAL)
                                                                                         │
NoteAnywhere.app ◀──── Darwin notification "com.memorynotes.changed" after every save ───┘
```

- **One binary, two roles.** Chrome launches the app's own executable as a short-lived native messaging host, so
  the extension works even when the app is closed.
- **SQLite in WAL mode** lets the app and the host write at once; a Darwin notification tells every process to
  reload. The extension keeps one host process open to hear about changes, so open tabs update live.
- **The browser panel lives in an extension iframe**, so pages can't see its keystrokes or styles.
- **One editor.** A TipTap (ProseMirror) Markdown editor, bundled into a single script, runs in the app's WKWebViews
  and in the extension.
- **Search** keeps a MiniLM vector per note; the score is cosine similarity plus a bonus for matching words.
- **Sync** pushes changed rows to Supabase, which keeps the newer edit by `updated_at` and stamps each write with a
  sequence number that devices pull from.

SwiftUI and AppKit, with no Xcode project: SwiftPM plus `scripts/install.sh`. Every decision and why it was made is
in [docs/DECISIONS.md](docs/DECISIONS.md).

The project used to be called MemoryNotes, and internal identifiers keep that name (bundle id, native host
`com.memorynotes.host`, the `memorynotes://` URL scheme, the data folder) so existing installs keep their notes,
permissions and sync.

## Coming soon

- **An iPhone app**, with a Share extension and a Safari extension (in progress).
- **An Apple Notes–style right-click menu** (in progress): Open in New Window, Pin, Lock (password-encrypted, unlock
  with Touch ID), New, Duplicate, Share, Move to Folder, color labels like Chrome's tab groups, Delete.
- **Folders and pinned notes**, synced (in progress).
- **iCloud sync** (planned).

See [docs/ROADMAP.md](docs/ROADMAP.md).

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

NoteAnywhere is free software under the [GNU General Public License v3.0](LICENSE).

## Credits and third-party licenses

| Component | Used for | License |
|-----------|----------|---------|
| [TipTap](https://tiptap.dev) and [ProseMirror](https://prosemirror.net) (with marked, linkifyjs and small helpers) | The shared editor, bundled in `editor/dist` and `extension/editor` | MIT |
| [swift-embeddings](https://github.com/jkrukowski/swift-embeddings) | Running MiniLM in Swift | MIT |
| Its dependencies: [swift-transformers](https://github.com/huggingface/swift-transformers), swift-huggingface, swift-jinja, swift-collections, swift-crypto, swift-asn1, swift-argument-parser, swift-safetensors, swift-sentencepiece, yyjson, EventSource | Loading and tokenizing the model | Apache-2.0 or MIT |
| [all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) | The search model, downloaded on first use | Apache-2.0 |
| [ui-review-tahoe skill](https://github.com/rshankras/claude-code-apple-skills), vendored in `.claude/skills/ui-review-tahoe` | UI review guidelines used while building | MIT |

NoteAnywhere was built with a lot of help from Claude Code. The decision log records which calls were the author's
and which the AI proposed.
