# Architecture

How NoteAnywhere is built: the apps, the browser extension, the editor they share, the database on each device and
the optional sync. The reasons behind each choice are in [DECISIONS.md](DECISIONS.md); "D31" and the like below are
its entries.

## In short

- **Local-first.** Every device keeps all its notes in its own store and works offline: SQLite on the Mac and
  iPhone, a JSON file on Android. Nothing needs a server.
- **A native app per platform**, with no cross-platform framework: SwiftUI and AppKit on the Mac, SwiftUI on iPhone,
  Kotlin and Jetpack Compose on Android. The iPhone app compiles the Mac's store, sync, search and encryption files
  as they are. Android re-implements what it needs.
- **One editor, written once.** A TipTap (ProseMirror) Markdown editor, built into one script, runs in the Mac app,
  the iPhone app and the browser extension. Notes are stored as Markdown text.
- **One Mac binary, three roles**: the app, the browser extension's native messaging host and an MCP server for AI
  assistants. All three use the same SQLite file and announce every change with one system-wide notification,
  `com.memorynotes.changed`.
- **Optional, end-to-end encrypted sync** through Supabase. Each device seals the text with AES-GCM before it
  leaves, so the server holds ciphertext. The server keeps the newer edit and numbers every change, so devices can
  pull just what's new.

```
Mac
  Chrome or Brave tab
    └─ panel iframe: overlay.js and the shared editor
         │ native messaging
         ▼
  MemoryNotes, as the browser's host ──┐
  MemoryNotes --mcp, for an AI app ────┼──▶  memorynotes.sqlite (WAL)
  NoteAnywhere.app, the app itself ────┘     every write posts com.memorynotes.changed
         │
         │ sync, if it's on: text sealed with AES-GCM before it leaves
         ▼
Supabase: Postgres with row-level security, Auth, Storage for images, Realtime
         ▲                                       ▲
         │ the same SyncCloud.swift              │ a Kotlin port of it
iPhone app, with Share and Safari extensions     Android app
  SQLite in the App Group                          notes.json
```

## The pieces

| Piece | Folder | Built with | What it does |
|---|---|---|---|
| Mac app | `Sources/MemoryNotes` | Swift and SwiftPM, SwiftUI and AppKit; macOS 15 or later | The app, the browser extension's host and the MCP server |
| Browser extension | `extension/` | Manifest V3, plain JavaScript | A page's notes, on the page, in Chrome and Brave |
| Shared editor | `editor/` | TipTap 3, KaTeX, Vite | The Markdown editor in the Mac app, the iPhone app and the extension |
| iPhone app | `ios/` | SwiftUI, XcodeGen; iOS 18 or later | The app, a Share extension and a Safari extension |
| Android app | `android/` | Kotlin, Jetpack Compose, Gradle; Android 8.0 or later | Read, search and write notes |
| Sync server | `supabase/` | Postgres migrations for Supabase | Keeps the encrypted rows and settles conflicts |
| Website | Not in this repo | Cloudflare | noteanywhere.app, the download, the update feed, feedback |

## The Mac app

### One binary, three roles

`Main.swift` looks at the arguments it was started with:

| Started by | Arguments | Runs | Lives |
|---|---|---|---|
| You | none | The app: menu-bar item, floating panel, main window | Until you quit it |
| A Chromium browser, for the extension | `chrome-extension://<extension id>/` | `NativeHost`: reads and writes notes for the browser panel | One request, or as long as the extension's `watch` port is open |
| An AI app (Claude, Codex, Gemini) | `--mcp` | `MCPServer`: search, read and edit notes over stdio | As long as the AI app keeps it |

Why (D3): Chrome starts the host itself, so website notes work while the app is closed, and only the extension ids
listed in the host's manifest can reach it. A localhost server would work only while the app runs, and any local
process or page could try it. Being the app's own binary, the host needs no second executable built and signed for
the same store code.

### Inside the app

From the bottom up:

1. **`NoteStore`** (`Note.swift`) does every read and write, as plain SQLite calls on one shared connection. After
   each committed change it posts the Darwin notification `com.memorynotes.changed`, which crosses processes.
2. **`NotesModel`** (`NotesModel.swift`) is one shared `ObservableObject` holding all notes, folders and daily
   snapshots. An edit updates its copy and saves at once. When `com.memorynotes.changed` arrives, from this process or
   another (the browser host, the MCP server, a sync pull), it reloads from SQLite. `FrontWindow`, a separate object,
   holds which app and place are in front, so the main window doesn't redraw on every window-title change.
3. **SwiftUI views**: the main window (`NotesWindow.swift`: notes, calendar, graph), the floating panel
   (`Overlay.swift`), the ⌥⇧Space search popup (`SearchViews.swift`), Settings, Welcome and Feedback. The menu-bar item
   is a `MenuBarExtra`.
4. **AppKit and older APIs where SwiftUI can't do the job**: the floating panel is a non-activating `NSPanel` (you can
   type in it without taking "frontmost" away from the app the notes are about, and it shows over full-screen apps),
   ⌥⇧M and ⌥⇧Space are Carbon hotkeys (no permission needed), and window titles come from the Accessibility API.

Shared state lives in a few singletons (`NotesModel.shared`, `CloudSync.shared`, `LockSession.shared`,
`IconStore.shared`). Views observe them directly; there are no per-view view models and no dependency injection.

### Following the app in front

```
NSWorkspace: another app became active
  → WindowTitleWatcher   Accessibility notifications from that app (focused window, main window, title changed);
                         in a browser, the address bar's text; in WhatsApp, the chat header, read once a second
  → WindowContext        "Sam (DM) - Acme - 8 new items - Slack"  →  "bundle.id/Acme/Sam (DM)"
  → FrontWindow          .context (the place) and .page (a browser's open page)
  → OverlayController    shows NotesModel.frontNotes(): the place's notes and those of every place under it
```

There is no parser per app: the same title rules work for every app (README, "How context detection works"). The
panel opens by itself when the place has app notes and auto-open is on. A web page's own notes are left to the
extension's panel in the page, so there aren't two panels (D69).

### Search, Apple Intelligence, calendar and graph

- **Search** (`SearchIndex.swift`, an actor): the all-MiniLM-L6-v2 model through `swift-embeddings`, downloaded once
  from Hugging Face into `models/` next to the database. The app re-embeds changed notes 2 seconds after typing stops
  and keeps the vectors in the `embeddings` table; other processes only read them. A result's score is cosine
  similarity plus 0.5 × the share of the query's words found in the note. A `#tag` query lists tagged notes instead.
  Locked notes are never embedded or searched.
- **Apple Intelligence** (`Assistant.swift`): Apple's on-device Foundation Models (macOS 26, iOS 26) proofread,
  improve, shorten, make a checklist or write a title. Nothing leaves the device.
- **Calendar** (`CalendarView.swift`): each day shows the lines dated to it (`@2026-10-30` in the text), tasks
  first, and what was edited that day, from the `snapshots` table, which keeps each note as it was at the end of every
  day it was edited. Ticking a task in the calendar ticks it in the note.
- **Graph** (`GraphLayout.swift`, `GraphView.swift`): a node per note, hubs per app or site and per #tag, and edges
  for links between notes, a note's source, its tags and similar meaning (MiniLM cosine ≥ 0.5, at most 3 per note),
  laid out by a d3-force–style simulation.
- **Tags and links** between notes are read from the Markdown each time they're needed. The `tags` and `links` tables
  that schema v1 created are unused.

### What it connects to

Nothing, unless you use a feature that needs it:

| What | Where | When |
|---|---|---|
| Sync | Supabase | sync is on |
| Search model | Hugging Face | the first search, once |
| Site icons | the site itself (its page's icon, then `/favicon.ico`), never a favicon service | a site's note first shows |
| Link previews | the pasted link | you paste a link as a mention or card |
| Updates | `noteanywhere.app/appcast.xml`, then GitHub Releases | once a day if you allowed it, or Check for Updates… |
| Feedback | `noteanywhere.app/api/feedback` | you send feedback |
| Google sign-in | Google | you sign in to sync with Google |

**Updates** use Sparkle 2. A release is accepted only if it's signed with the key whose public half is `SUPublicEDKey`
in `Info.plist` (D75). `scripts/install.sh` removes `SUFeedURL` from dev builds, so they never replace themselves
with a release.

## Data on a device

### The SQLite file

`~/Library/Application Support/MemoryNotes/memorynotes.sqlite` on the Mac (or `$MEMORYNOTES_DIR`). It runs in WAL
mode with a 5-second busy timeout, so the app and the host processes can write at the same time. The schema version
is `PRAGMA user_version` (now 7), and `NoteStore.migrate` upgrades it inside `BEGIN IMMEDIATE`, because the app and
the browser host may open the file at the same moment. The pre-SQLite JSON files are imported once and kept, renamed
`*.imported` (D18).

| Table | What it holds |
|---|---|
| `notes` | One row per note: id, kind, target, title, Markdown text, created / updated / deleted times, pinned, starred, folder, colour, locked, dirty |
| `snapshots` | The note's text at the end of each local day it was edited, keyed by (note, day); the calendar's history |
| `folders` | Id, name, updated / deleted times, dirty |
| `images` | Id, type and time per image; the bytes are files in `images/<id>` |
| `embeddings` | Search vectors per note and model |
| `icons` | Site icons as PNG |
| `sync_state` | Sync's pull cursor per table |
| `suggestions`, `tags`, `links`, `attachments` | Made by early migrations; nothing writes them now |

Rules every writer follows:

- **Times are milliseconds since 1970**, as doubles, everywhere: SQLite, the server, JSON.
- **Ids are lowercase UUIDs** (D76).
- **Deletes are soft** (`deleted_at`), so sync can carry them. Reads skip deleted rows, and saving a deleted note
  doesn't bring it back.
- **`dirty = 1`** marks a row changed here and not pushed yet.
- Saving a note also saves that day's snapshot, in the same transaction.
- A pin, colour or folder change adds 1 ms to `updated_at` instead of taking "now": enough for sync's newer-wins rule
  to carry it, without moving the note to "Today" in the list.

### A note

- **`kind`** is `app` or `url`. An app note's **`target`** is its place, `bundle.id/Acme/Sam (DM)`. A website note's
  is `host/path`, like `github.com/apple/swift` (a YouTube video or a search keeps its query, D70). A plain note is a
  `url` note with an empty target (D33).
- **A place sees the notes of the places under it**: `github.com` lists `github.com/apple/swift`'s notes, and
  Slack › Acme lists the notes of all its channels (D19, D23).
- **The text is Markdown**: `#tags`, dates as `@2026-10-30` (which Obsidian reads too), links to other notes as
  `note://<id>`, and images as `![](noteimage:<id>)`, which the apps' web views load through a custom URL scheme
  (`ImageScheme.swift`).
- **A locked note's text is an envelope**: `mnlock:v1:` + base64(salt | nonce | ciphertext | tag), AES-GCM with a key
  from PBKDF2-SHA256(notes password, salt, 310,000 rounds) (`NoteLock.swift`). Locking also replaces the note's
  snapshots with the envelope and deletes its search vector, so no readable copy is left in the database or, through
  sync, in the cloud. The browser is never sent locked notes.

## The browser extension

`extension/`: Manifest V3 and plain JavaScript, with no build step of its own (the editor inside it is the built
bundle). It runs in Chrome and Brave, and the same files become the Safari extension on iPhone.

| File | Runs in | Job |
|---|---|---|
| `content.js` | Every page | Tracks the page's address and title, and places the panel's iframe. It never shows notes itself. |
| `overlay.html`, `overlay.js` | An extension iframe in the page | The panel: the page's notes, the editor, search, new notes |
| `background.js` | The service worker | ⌥⇧N (it injects `content.js` into a tab that doesn't have it yet) and the live-update port |
| `editor/` | The iframe | The shared editor, copied there by the editor's build |

The panel is an iframe so the page's scripts can't see its keystrokes or styles. The page can only reach it through
extension messaging, which it can't forge (D17).

### Reaching the notes

An extension can't read files, so the panel asks the Mac app through Chrome's native messaging:

```
overlay.js    ── sendNativeMessage ──────▶  MemoryNotes, a new host process per request  ──▶  memorynotes.sqlite
background.js ── connectNative "watch" ──▶  one long-lived host process ── "changed" ──▶ every open panel reloads
```

- **Messages** are JSON with an `op`: `list` (a page's notes and those of the pages under it), `save`, `delete`,
  `search`, `addImage`, `image`, `linkPreview`, `ai` (Apple Intelligence, run on the Mac) and `watch`. Every reply
  has `ok`, and `error` when it failed. Framing is Chrome's: a 4-byte little-endian length, then UTF-8 JSON. Images
  come back in 600,000-byte pieces, under Chrome's 1 MB reply limit.
- **The host only saves website notes.** Locked notes never reach the browser, and a save from a tab can't replace a
  locked note's envelope with plain text.
- **Live updates.** Every save, from any process, posts `com.memorynotes.changed`. The `watch` process passes it on,
  `background.js` tells the panels 250 ms after the last one, and a visible panel reloads its list unless you're typing
  in it. The `watch` port opens when a panel first shows and then stays open, which also keeps the service worker
  alive.

### Registering the host

At every launch, `BrowserBridge.swift` writes `com.memorynotes.host.json` into `NativeMessagingHosts/` for each
Chromium browser it finds installed: Chrome (and its Beta and Canary), Chromium, Brave, Edge, Arc and Vivaldi. The
file points at the app's own executable and allows two extension ids: the unpacked one, fixed by the `key` in
`manifest.json`, and the Chrome Web Store one. `scripts/release.sh` takes the `key` out of the Web Store zip, because
the store assigns the id itself. Builds that aren't in an `.app`, and copies macOS has translocated, register nothing.

## The shared editor

`editor/`: TipTap 3 (ProseMirror) with KaTeX for maths (D11, D21). Vite builds it into one classic script and one
stylesheet, `mn-editor.js` and `mn-editor.css`, which define the global `MNEditor`. `npm run build` also writes
`shortcuts.json` and copies the output into `extension/editor`. The built files are committed, because the extension
loads straight from the repo.

- **Markdown in, Markdown out.** The editor loads a note's Markdown and hands back `getMarkdown()` after every
  change, so storage, sync, search and the MCP server only ever deal with Markdown text. `#tags` and `@dates` are only
  highlighted, not turned into nodes, so the text stays as typed. Maths (`$…$`, `$$…$$`), link mentions and link
  cards have their own Markdown rules.
- **Extensions:** TipTap's StarterKit, task lists, tables, images, maths and placeholder, plus NoteAnywhere's own:
  tags, dates, the `/` block menu, the ⋮⋮ drag handle, link mentions and link cards.
- **One API for every host.** `MNEditor.mount()` returns the editor with `setMarkdown`, `getMarkdown`, `focus` and a
  few more, and each host passes in its callbacks:
  - **The Mac and iPhone apps** load `app/editor.html` in a `WKWebView`. That page defines `window.MNHost` (`load`,
    `set`, `focus`, `reply`…) for Swift to call, and forwards the editor's callbacks to the `mn` script message
    handler. Some messages only inform (`ready`, `change`, `height`, `tag`, `date`, `openNote`). Others carry an id
    and wait for Swift's answer through `MNHost.reply` (`ai`, `addPage`, `addImage`, `linkPreview`, `findNotes`,
    `findTags`, `notePreview`). Images load through the `noteimage:` URL scheme (`ImageScheme.swift`). The Mac's
    wrapper is `EditorView.swift` and the iPhone's is `ios/App/NoteEditor.swift`. Both fall back to a plain text view
    if the bundle is missing.
  - **The browser panel**: `overlay.html` loads the bundle, and `overlay.js` mounts one editor per note. It saves
    400 ms after typing stops, sends images and ✨ requests through native messaging, and turns image pieces back
    into `blob:` URLs.

## Sync

Optional, and off until you turn it on (D31, D39). Each device keeps its own database. The server is Supabase:
Postgres with row-level security, Auth, Storage for images and Realtime. Its schema is in `supabase/migrations`.

### The server

- Tables `notes`, `snapshots`, `folders`, `images` and `vaults`. Every row carries `user_id`, and row-level security
  keeps each account to its own rows. Images' bytes are in a private Storage bucket, under `<user id>/<image id>`.
- One trigger, `sync_accept`, runs before every insert and update:
  - an update older than the stored row (by `updated_at`) is dropped, so a device that was offline can't overwrite
    newer text;
  - a deleted note or folder stays deleted;
  - every accepted write gets the next number from one sequence, `seq`, which devices pull by.
- Realtime publishes changes to `notes` and `folders`.

### A sync round (`SyncCloud.swift`)

1. **Push** the rows marked dirty: images first (the sealed bytes to Storage, then their rows), then folders, notes
   and snapshots, since each refers to the one before. They're upserts with every column, in batches. Afterwards a
   row is marked clean only if nobody edited it in the meantime.
2. **Pull** each table's rows with `seq` above that table's saved cursor, 500 at a time, and apply them with the same
   rules as the server: the newer `updated_at` wins, and deletes stick. Then move the cursor.
3. Rounds don't overlap. A round asked for while one is running starts when that one is done.

On the Mac, a full round runs at launch, every 60 seconds and whenever Realtime reports a change from another device.
A local save, from whichever process (the `com.memorynotes.changed` notification), triggers a push 2 seconds later.

### End-to-end encryption

- The first device makes a random 256-bit **vault key**. The server keeps it only wrapped: AES-GCM under
  PBKDF2-SHA256(sync passphrase, salt, 310,000 rounds), in `vaults`. The first device inserts it, so a second device
  racing it can't replace it; every other device enters the passphrase once. The key is then kept in the device's
  secure storage (see the table below).
- Before upload, each note's text, place and title, each snapshot's text and each folder's name become
  `mne2e:v1:` + base64(nonce | ciphertext | tag), AES-GCM with the vault key. Image bytes are sealed with the same
  key, as raw nonce | ciphertext | tag.
- The server sees ids, times (so also which days a note was edited), kind, pinned / starred / colour / folder ids,
  the locked flag, each image's type and size, and the account's email.
- Sync won't run without the vault key, so nothing goes up unencrypted. A forgotten passphrase loses the cloud copy,
  not the notes on your devices.

**Sign-in** is Supabase Auth: a link or code sent by email, or Google (Mac and iPhone). The session is kept with the
vault key, never in the notes database.

### Sync on each platform

| | Mac | iPhone | Android |
|---|---|---|---|
| Code | `SyncCloud.swift` | The same file | `Cloud.kt` and `Vault.kt`, a port of it |
| What syncs | Notes, folders, snapshots, images | Notes, folders, snapshots, images | Notes and folders |
| Full rounds | At launch, every 60 s, on Realtime events | The same, and whenever the app comes to the front | When the app comes to the front, when the list opens, on pull-to-refresh |
| Push after an edit | 2 s after the save | 2 s after the save | 2 s after the save (made 0.5 s after typing stops), and when you leave the app |
| Sign-in | Email link or code, Google | Email link or code, Google | Email code or link |
| Keys kept in | The Keychain | The Keychain | A file sealed by an Android Keystore key |

## The iPhone app

`ios/`, for iOS 18 or later on iPhone and iPad (D41). XcodeGen generates the Xcode project from `ios/project.yml`;
the `.xcodeproj` isn't committed.

**Mac code, compiled by path.** There's no shared Swift module. The iPhone targets compile the Mac's own files from
`Sources/MemoryNotes`, so the Mac code needs no `public` and there's one copy of the store, sync, search and
encryption code. Where a shared file must differ, it uses `#if os(iOS)`. The views and the model
(`ios/App/NotesModel.swift`) are the iPhone's own.

| Target | What it is | Mac files it compiles |
|---|---|---|
| `MemoryNotes` | The app: Notes, Calendar, Graph and Settings tabs (a sidebar on iPad) | `Note`, `NoteDates`, `WindowContext`, `SearchIndex`, `Assistant`, `GraphLayout`, `NoteLock`, `Accent`, `SyncCloud`, `SyncSettingsView`, `ImageScheme`, `LinkPreview`, `FeedbackView` |
| `MemoryNotesShare` | Share extension: a shared page becomes a note for that page, and shared text becomes the note's text | `Note`, `Accent` |
| `MemoryNotesSafari` | Safari web extension: a page's notes on the page | `Note`, `SearchIndex`, `Assistant`, `NativeHost`, `LinkPreview` |
| `MemoryNotesUITests` | UI tests, run from Xcode on a simulator | none |

**One database for the app and both extensions.** `memorynotes.sqlite`, the images and the search model live in the
App Group container (`group.com.memorynotes`). The extensions write straight into it and post
`com.memorynotes.changed`. The app reloads when it hears that or comes to the front. Only the app syncs.

**The Safari extension is the Chrome extension.** The build copies `extension/` into it and rewrites
`manifest.json`, `overlay.html` and `overlay.js` on the way. Safari on iOS kills pages whose extension frame calls
`tabs.*`, so two shims send those calls, and `sendNativeMessage`, through the background page (D41). Native messages
reach `SafariWebExtensionHandler`, which runs the Mac host's own `NativeHost.handle` on the shared database. Live
updates (`watch`) aren't available in Safari.

**The editor** is the shared TipTap editor in a `WKWebView` (`ios/App/NoteEditor.swift`). The build copies
`editor/dist` and `app/editor.html` into the app. If the script is missing, a plain text view takes its place. Images,
✨ actions (iOS 26) and Writing Tools work as on the Mac.

**Sync** is the Mac's `SyncCloud.swift`, with the same rounds, plus one whenever the app comes to the front. You sign
in with an emailed link or code, or with Google in a web sign-in sheet.

**Not there yet:** locked notes show a placeholder and can't be opened on the phone.

## The Android app

`android/`: Kotlin and Jetpack Compose (Material 3), Android 8.0 or later, application id `com.memorynotes.android`
(D66). Gradle builds a debug APK that you install yourself. It isn't on Google Play.

Android shares no code with the Mac. It re-implements what it needs, in the Mac's formats, and its tests check the
encryption against values the Mac's own crypto produced.

| File | Job |
|---|---|
| `MainActivity.kt` | The one activity and every screen: sign-in, the sync passphrase, the note list and the editor. One `App` object holds the store and the sync client; there's no navigation library and no ViewModel. |
| `Store.kt` | Notes, folders and sync cursors in one JSON file, `notes.json` in the app's private storage, rewritten through a temporary file on every change. The same rules as `NoteStore`: the newer edit wins, deletes stick, dirty flags. |
| `Cloud.kt` | Sync: the same requests as `SyncCloud.swift`, over `HttpURLConnection` |
| `Vault.kt` | The same encryption: PBKDF2-HMAC-SHA256, written out by hand so every Android crypto provider reads the passphrase as UTF-8, and AES-256-GCM |
| `Secrets.kt` | The session and the vault key, in one file sealed by an AES key that never leaves the Android Keystore |
| `Note.kt` | The note model and its title |
| `Feedback.kt` | The feedback form, sent to the website's `/api/feedback` |

**What it does:** sign in with the emailed code (or the link), enter or create the sync passphrase, then list,
search, write and delete notes in a plain Markdown text box, filter by folder, and pin, star and colour notes. Search
matches words, not meaning.

**Not there yet:** the calendar, the graph, the shared editor, images, search by meaning, creating or renaming
folders or moving notes into them, and opening locked notes. Snapshots and images aren't synced.

## The MCP server

`MemoryNotes --mcp` (`MCPServer.swift`) lets Claude, Codex and Gemini search, read and edit notes (D50). It speaks
JSON-RPC over stdin and stdout, one message per line, and answers both the current protocol and the older
`initialize` handshake most clients still use. Its tools call `NoteStore` and `SearchIndex` directly, so every write
lands in the same SQLite file and the running app hears of it through `com.memorynotes.changed`.

It can't delete notes or open locked ones, and `replace_note_text` only replaces a note if its `updated_at` still
matches what the assistant read, so it can't overwrite an edit it never saw.

## Build, release and tests

- **Mac:** no Xcode project (D1). `Package.swift` has one executable target and one test target, and two
  dependencies: `swift-embeddings` (MiniLM) and Sparkle. `scripts/make_app.sh` turns the binary into
  `NoteAnywhere.app`: `Info.plist` with the version from `VERSION`, `Sparkle.framework`, the dependencies' resource
  bundles, the icon (drawn by `scripts/make_icon.swift`) and the editor, which it builds and copies in with
  `app/editor.html`.
  - `scripts/install.sh` makes a dev build in `~/Applications` and launches it. It's signed with your Apple
    Development certificate if you have one, so the Accessibility permission survives rebuilds, and has no update
    feed.
  - `scripts/release.sh` is for the maintainer: a universal binary (Apple silicon and Intel), hardened runtime with
    no entitlements and no sandbox, signed with a Developer ID, notarized and stapled, in a DMG. It also builds the
    Chrome Web Store zip.
- **iPhone:** `cd ios && xcodegen generate`, then build in Xcode or with `xcodebuild`.
- **Android:** `cd android && ./gradlew assembleDebug`. The version comes from the same `VERSION` file.

| Test | What it checks |
|---|---|
| `swift test` | The Mac's logic: window titles to places, note text, tags and dates, the graph, link previews, images, locked notes, the sync store and its encryption, the MCP server, the browser bridge, screen geometry, the updater |
| `swift build -c release && python3 scripts/test_host.py` | The native messaging host end to end, with Chrome's framing, on a scratch store |
| `node scripts/test_mcp.mjs`, `python3 scripts/test_mcp.py` | The MCP server end to end over stdio, on a scratch store |
| `node scripts/test_overlay.mjs` | The browser panel in headless Chromium with the unpacked extension (needs Playwright) |
| `cd editor && npm test` | The shared editor in Node with happy-dom: Markdown round trips and editing |
| `cd android && ./gradlew testDebugUnitTest` | Android's store rules and encryption, against values made by the Mac's crypto |
| `MN_UI_PROBE=1 swift test --filter dividerDrags` | Opt-in, and run it alone: drags the real main window's dividers, off-screen (D80) |
| `ios/UITests` | The iPhone app's UI tests, from Xcode on a simulator |

## Not in this repo

- **The website**, noteanywhere.app: its pages, the DMG download, the update feed (`appcast.xml`) and the feedback
  endpoint (`/api/feedback`) run on Cloudflare, from a private repo (D71, D74).
- **Release signing keys**: the Developer ID certificate and Sparkle's private key are kept on the maintainer's Mac.

## Old names

The project used to be called MemoryNotes. Internal identifiers keep that name: the bundle id `com.memorynotes.app`,
the native host `com.memorynotes.host`, the `memorynotes://` URL scheme, the App Group `group.com.memorynotes` and the
data folder. Changing them would cost existing installs their notes, permissions and sync. Text people see says
NoteAnywhere.
