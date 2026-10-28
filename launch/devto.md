---
title: "How my Mac notes app knows which Slack DM you're in (and other macOS plumbing)"
published: false
description: "Building NoteAnywhere: Chrome native messaging to a Swift binary, Accessibility window titles, on-device MiniLM search, Apple Foundation Models, SQLite + Darwin notifications, and Supabase sync."
tags: swift, macos, opensource, webdev
cover_image: {{COVER_IMAGE_URL}}
---

NoteAnywhere is a notes app for macOS with a Chrome/Brave extension. The idea is small: a note belongs to a place.
Write it while you're in a Slack DM, a VS Code project, a WhatsApp chat or on a GitHub page, and the next time you're
there, it shows up in a floating panel. It's free and open source (GPL-3.0).

![A Slack DM opens and its notes appear in NoteAnywhere's floating panel]({{HERO_GIF_URL}})

This post is about how it works, because most of the interesting parts are glue between systems that weren't made to
talk to each other: a browser extension and a Swift app, a window title and a "place", a sentence model and a SQLite
file. I'll show the real code (trimmed) and be upfront about the limits.

A naming note: the project was called MemoryNotes until recently, and internal identifiers (bundle id, native host
name, URL scheme, data folder) still say so, so existing installs keep their data. You'll see that name in the code.

## The shape of it

```
Chrome/Brave tab ─content.js─▶ overlay.html (extension iframe) ─Native Messaging─▶ NoteAnywhere binary (host mode)
                                                                                         │
                                     ~/Library/Application Support/MemoryNotes/memorynotes.sqlite (WAL)
                                                                                         │
NoteAnywhere.app ◀──── Darwin notification "com.memorynotes.changed" after every save ───┘
```

SwiftUI and AppKit, built with SwiftPM and a shell script (no Xcode project). One TipTap editor bundle runs in both
the app and the extension. Everything below hangs off that diagram.

## 1. One binary, two jobs: Chrome native messaging

Browser extensions can't touch the filesystem. The usual escape hatches are a localhost server in the app or Chrome's
[native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging). A local server
only works while the app runs, and any local process or web page can try to reach it. Native messaging only answers
the extension ids listed in the host manifest, and Chrome starts the host on demand, so the extension works even when
the app is closed.

I didn't want a second executable for the host, so the app binary checks how it was launched. Chrome passes the
calling extension's origin as the first argument:

```swift
@main
enum Main {
    static func main() {
        // Chrome/Brave launch this same binary as the native messaging host, passing the extension origin.
        if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true {
            NativeHost.run()
        }
        MemoryNotesApp.main()
    }
}
```

The protocol is a 4-byte little-endian length followed by UTF-8 JSON, on stdin and stdout:

```swift
static func run() -> Never {
    signal(SIGPIPE, SIG_IGN)  // a closed tab mid-reply should fail the write, not kill the process
    let stdin = FileHandle.standardInput
    while true {
        let header = stdin.readData(ofLength: 4)
        guard header.count == 4 else { exit(0) }  // Chrome closed the pipe
        let length = UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        send(handle(stdin.readData(ofLength: Int(length))))
    }
}
```

The host speaks a handful of ops: `list`, `save`, `delete`, `search`, `ai` and `watch`. It's also a trust boundary,
so it checks what comes in. Note ids must be UUID characters (they end up in SQL and used to end up in file paths), and
the browser may only write website notes, never app notes:

```swift
case "save":
    // The browser may only write website notes, never app notes.
    guard var note = req.note, note.kind == .url, !note.target.isEmpty else {
        return Reply(ok: false, error: "save needs a website note with a target")
    }
```

A Python script (`scripts/test_host.py`) frames JSON exactly like Chrome does and runs these cases against a temp
database, including "a non-UUID id is rejected" and "the browser can't take over an app note by reusing its id".

One small trick for the unpacked build: the host manifest has to name the extension id, and an unpacked extension's id
changes with its folder unless the manifest carries a `key`. With a fixed `key`, the id is derived from it, and the
install script computes it the same way Chrome does, first 32 hex characters of the SHA-256, mapped `0-f` to `a-p`:

```sh
ID=$(python3 -c 'import json; print(json.load(open("extension/manifest.json"))["key"])' \
  | base64 -d | shasum -a 256 | head -c 32 | tr 0-9a-f a-p)
```

## 2. The browser panel lives in an iframe, because pages steal focus

The first browser panel was a normal content-script UI injected into the page. On several sites, typing in it went
into the site's own text box: pages listen for keystrokes globally and redirect them, or grab focus back.

The fix was to move the whole UI into `overlay.html`, an extension page loaded in an iframe. The content script only
places the frame and reports the URL:

```js
const frame = document.createElement("iframe");
frame.src = chrome.runtime.getURL("overlay.html");
// The frosted glass lives here: a backdrop-filter inside the cross-origin frame can't see the page behind it.
frame.style.cssText = "all: initial; position: fixed; top: 8px; right: 8px; width: 340px; height: 0; border: 0;" +
  "z-index: 2147483647; display: none; /* … */";
document.documentElement.append(frame);
```

The frame is cross-origin to the page, so page scripts never see its keystrokes, focus or styles. Page context (URL,
title) reaches the frame through extension messaging, which the page can't forge, unlike `postMessage`.

I tested this with Playwright against Chromium: a page that redirects every keystroke to its own input no longer got
the panel's typing, 5 runs out of 5. A page that re-focuses its own input on *every* blur still wins. The page can't
see the pointer enter the frame, so there's no page-side fix; I accepted that as a known limit.

Two side effects of living in a cross-origin frame: `confirm()` is blocked, so deleting a note takes a second click,
and the frame can't see the page's viewport, so the content script reports `innerHeight` back to it to cap the
panel's height.

## 3. Turning a window title into a place

On the Mac side, the question is "where is the user right now?" Screen Recording could answer it, but it's a scary
permission and needs polling. The Accessibility API is enough: it gives you the focused window's title, and it can
notify you when that changes.

```swift
let element = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(element, 0.5)  // a hung app must not stall our main thread
// …
// Registered on the app element, these fire for all of its windows.
for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXTitleChangedNotification] {
    AXObserverAddNotification(created, element, name as CFString, refcon)
}
CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
```

Then the title has to become a path. Titles look like `Sam (DM) - Acme - 8 new items - Slack` or
`index.ts — weather-app — Visual Studio Code`. I tried not to write per-app parsers. The rules are generic:

- split on ` - `, ` — `, ` – ` and ` | `;
- find the app's own name at one end, which tells you which end is the broad one;
- drop parts that change without the place changing: unread counts, "8 new items", unsaved dots;
- reverse if needed, so the path goes broad to narrow.

```swift
var parts = title.split(separator: #/\s[-—–|]\s/#).map { clean(String($0)) }
// …
parts.removeAll { $0.isEmpty || $0.contains(#/^(\d+\s+(new\s+items?|unread.*|notifications?|messages?)|edited)$/#.ignoresCase()) }
if !broadFirst { parts.reverse() }
return parts.map { $0.replacingOccurrences(of: "/", with: "∕") }  // "/" separates levels in the target
```

So that Slack DM becomes `Slack › Acme › Sam (DM)`, and the note's target is
`com.tinyspeck.slackmacgap/Acme/Sam (DM)`. Website notes use `host/path` targets, and both follow the same rule: a
place sees its own notes plus the notes of places under it. Slack › Acme shows the notes of every channel in it;
`github.com` shows the notes on `github.com/apple/swift`.

In SQLite that rule is a range query on an index. `"0"` sorts right after `"/"`, so `[page/, page0)` is exactly the
targets under a page:

```sql
WHERE deleted_at IS NULL AND kind = 'url' AND (target = ?1 OR (target >= ?2 AND target < ?3))
-- ?1 = page, ?2 = page + "/", ?3 = page + "0"
```

### WhatsApp, the app whose title says nothing

WhatsApp's window title is just "WhatsApp", whichever chat is open. For apps like that there's a small table: the
accessibility identifier of the element that names the open conversation.

```swift
static let conversationHeaders = ["net.whatsapp.WhatsApp": "NavigationBar_HeaderViewButton"]
```

Only that element's description is read. The depth-first search that finds it skips tables and the chat list, which
are big and none of our business:

```swift
/// Depth-first search for the element with this identifier; returns its description. Message lists are skipped:
/// they're big, and their contents are none of our business.
private func find(_ identifier: String, in element: AXUIElement, depth: Int) -> String? {
    if Self.string(element, kAXIdentifierAttribute) == identifier { return Self.string(element, kAXDescriptionAttribute) }
    guard depth < 8, Self.string(element, kAXRoleAttribute) != kAXTableRole else { return nil }
    // …
    for child in (children as? [AXUIElement]) ?? [] {
        if let id = Self.string(child, kAXIdentifierAttribute), id.hasSuffix("TableView") || id.hasPrefix("ChatListView") { continue }
        if let found = find(identifier, in: child, depth: depth + 1) { return found }
    }
    return nil
}
```

Switching chats fires no notification I could observe, so while WhatsApp is in front this check runs once a second.
That's the only polling in the context code.

### A bug that cost 5% CPU

After a while I noticed the app sitting at about 5% CPU while idle, but only when a terminal was in front. The
terminal was running a tool with an animated spinner in its title (`✳ Claude Code`). Every frame of the spinner
changed the title, every title was a "new place", and the main window redrew each time.

The fix had two parts: strip leading non-letter characters as part of cleaning a title part (that covers
unsaved dots, bullets and spinners alike), and move "which app and place is in front" into its own observable object,
so views that don't show it don't redraw when it changes.

```swift
.replacing(#/^[^\p{L}\p{N}(\[#@~]+/#, with: "")  // unsaved dots, spinners ("✳ Claude Code"), bullets
```

Idle CPU is now about 0%, and the app uses about 37–65 MB of memory in my measurements.

## 4. Semantic search with MiniLM, plus plain keywords

Search is a Spotlight-style popup on ⌥⇧Space, plus a search box in both panels. I wanted it to find "the note about
the flaky deploy" when the note says "CI pipeline keeps failing".

I first tried Apple's built-in embeddings, since they're free and already on the Mac. On a tiny benchmark I put
together (8 sample notes, 7 paraphrased queries, top-1 hit), the results were:

| Model | Top-1 hits |
|-------|-----------|
| Apple `NLEmbedding.sentenceEmbedding` | 2/7 |
| Apple `NLContextualEmbedding`, mean-pooled | 2/7 |
| all-MiniLM-L6-v2 | 6/7 |
| bge-small-en-v1.5 | 6/7 |
| multilingual-e5-small | 6/7 |

That's far too small a set to rank the three good models against each other, but it was enough to rule out the
built-in ones. I picked all-MiniLM-L6-v2: it's small (about 87 MB on disk, downloaded once on the first search), and
[swift-embeddings](https://github.com/jkrukowski/swift-embeddings) runs it in Swift with `MLTensor` on macOS 15.

```swift
var options = bundle.defaultEncodeOptions
options.maxLength = 256  // MiniLM was trained on 256 tokens; longer notes are truncated
options.postProcess = .meanPool(normalize: true)
```

Embeddings alone miss exact words, names and non-English text, so the score is hybrid:

```swift
let keyword = Double(words.filter { haystack.contains($0) }.count) / Double(words.count)
// …
// Vectors are normalized, so the dot product is cosine similarity; unrelated MiniLM pairs sit below ~0.25.
if similarity > 0.25 || keyword > 0 {
    hits.append(Hit(note: note, score: similarity + 0.5 * keyword))
}
```

A search for exactly `#tag` skips all of this and lists the notes with that tag, like Obsidian.

The app keeps one vector per note in SQLite (Float32 BLOBs) and re-embeds a note two seconds after you stop typing.
The browser host only reads those vectors and embeds the query. Since Chrome starts a fresh host process per
one-off message, each browser search loads the model, which made a search through the host take about 0.4 s. Fine
for a search box.

## 5. Apple Intelligence, on-device

macOS 26 ships Apple's on-device language model through the Foundation Models framework. NoteAnywhere uses it for a
✨ menu: Fix Spelling & Grammar, Make Clearer, Make Shorter, Turn into Checklist, Add Title. The API is pleasantly
small:

```swift
let session = LanguageModelSession(instructions: """
    You edit personal notes written in Markdown. \(action.instruction)
    Keep Markdown formatting (headings, lists, checkboxes, links, code) unless asked to change it.
    Reply with the result only: no preamble, no explanation, no surrounding code fence.
    """)
let reply = try await session.respond(to: markdown).content
```

Most of the work is in the edges:

- **Availability.** `SystemLanguageModel.default.availability` tells you whether Apple Intelligence is off, still
  downloading, or unsupported on this Mac, and each case gets its own message.
- **Errors.** A note too long for the context window asks you to select part of it; a guardrail refusal says so
  plainly.
- **Cleanup.** Models sometimes wrap the answer in a code fence or quotes anyway, so a small `clean()` strips them.

On the editor side, the result has to land safely. The editor locks itself while the model runs, then refuses to apply
the result if the document changed in the meantime, and applies it as one chain, which is one undo step:

```js
const before = editor.state.doc;
editor.setEditable(false); // the result replaces this exact text
try {
  const result = await onAI(action, input);
  editor.setEditable(true);
  if (!editor.state.doc.eq(before)) throw new Error("The note changed meanwhile, so nothing was replaced.");
  const chain = editor.chain().focus();
  // … replace the selection or the whole note
  chain.run();
```

In the browser, `onAI` sends `{op: "ai"}` to the native host, so the model still runs on the Mac and nothing goes to a
server. The app's editors also allow the system Writing Tools (`writingToolsBehavior = .complete` on the
`WKWebViewConfiguration`).

## 6. SQLite and Darwin notifications for live updates

Notes started as one JSON file per note. Every new feature (history, vectors, icons) was going to bolt on its own files, so it's now
one SQLite database in WAL mode, shared by the app and the short-lived host processes:

```swift
sqlite3_busy_timeout(handle, 5000)  // the app and the browser host may write at the same moment
for pragma in ["PRAGMA journal_mode = WAL", "PRAGMA foreign_keys = ON"] {
    sqlite3_exec(handle, pragma, nil, nil, nil)
}
```

Migrations use `PRAGMA user_version` inside `BEGIN IMMEDIATE`, re-checking the version, because the app and a host
can start at the same moment. The old JSON files were imported once and renamed, not deleted.

Two processes writing one database still need to tell each other. macOS has a tiny cross-process signal for that:
Darwin notifications. Every committed save posts one:

```swift
notify_post("com.memorynotes.changed")
```

The app reloads when it hears it:

```swift
notify_register_dispatch(NoteStore.changed, &notifyToken, .main) { [weak self] _ in self?.reload() }
```

The other direction (app to browser) needed one more piece. The extension's service worker keeps a single
`connectNative` port open and sends `{op: "watch"}`. That host process registers for the same notification and streams
an event down the pipe on every save, from any process:

```swift
case "watch":
    // On a long-lived port (connectNative): push an event whenever the app or any host process saves.
    if watchToken == 0 {
        notify_register_dispatch(NoteStore.changed, &watchToken, DispatchQueue(label: "watch")) { _ in
            send(Reply(event: "changed"))
        }
    }
    return Reply()
```

The service worker debounces for 250 ms (the app saves on every keystroke) and tells visible panels to reload. A
panel never replaces an editor that has focus. Replies and events share stdout, so writes go through a lock. A side
benefit: an open native port keeps the MV3 service worker alive.

## 7. Optional sync: Supabase, last writer wins, sequence cursors

Sync is off by default. When it's on, each device keeps its own SQLite database, and two Postgres tables on Supabase
(`notes` and `snapshots`) mirror it, with row level security per user. Sign-in is an emailed link that opens the app
through a custom URL scheme, or the code from the same email.

The conflict rule lives in a trigger, so no client can get it wrong:

```sql
create function public.sync_accept() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
    if new.updated_at < old.updated_at then return old; end if;
    if tg_table_name = 'notes' and old.deleted_at is not null then
      new.deleted_at := old.deleted_at;
    end if;
  end if;
  new.seq := nextval('public.sync_seq');
  return new;
end $$;
```

Three things happen there. An older edit (a device that was offline) can't overwrite newer text. A delete is a
tombstone that stays deleted. And every accepted write gets a new number from one sequence, which is what devices pull
by:

```swift
let cursor = NoteStore.syncValue("cursor.\(table)") ?? "0"
let data = try await rest("\(table)?select=\(columns),seq&seq=gt.\(cursor)&order=seq.asc&limit=500", method: "GET")
```

Pushing is "send rows marked dirty, then clear the flag only on rows nobody edited meanwhile":

```sql
UPDATE notes SET dirty = 0 WHERE id = ? AND updated_at = ?
```

Live updates use Supabase Realtime, spoken directly over `URLSessionWebSocketTask` (it's the Phoenix channel
protocol: join a topic, send a heartbeat every 25 s). Any change to the notes table triggers a pull. A 60-second timer
covers the gaps when the socket drops during sleep.

One small PostgREST gotcha: a batch insert takes its columns from the first object, so nulls have to be explicit on
every row: if the first row leaves out `deleted_at`, the column is dropped for the whole batch.

And one known shortcut, written down in the code: a row committed out of sequence order by a concurrent writer could
be skipped by a puller until it changes again. For one person's devices that's acceptable; a server-side "changes
since" function would close it.

## 8. One editor in two hosts

I wanted the same editor in the Mac app and the browser panel: headings, lists that keep numbering, checklists,
tables, links between notes, and Markdown as the storage format, so notes stay readable, searchable and easy to sync.
That's [TipTap](https://tiptap.dev) (on ProseMirror), pinned to 3.32.

Vite builds it into one classic script plus one stylesheet (about 505 kB, 158 kB gzipped). Classic, not ES modules,
because then both hosts load it the same way, with a plain `<script src>`:

```js
export default defineConfig({
  build: {
    outDir: "dist",
    lib: { entry: "src/index.js", name: "MNEditor", formats: ["iife"], fileName: () => "mn-editor.js", /* … */ },
  },
});
```

In the Mac app, each editor is a transparent `WKWebView`. Swift calls into a small `MNHost` object, and the page talks
back through `webkit.messageHandlers`:

```js
const post = (msg) => webkit.messageHandlers.mn.postMessage(msg);
window.MNHost = {
  load(markdown, options) {
    editor = MNEditor.mount(document.getElementById("editor"), {
      markdown, ...options,
      onChange: (md) => post({ type: "change", markdown: md }),
      onTag: (tag) => post({ type: "tag", tag }),
      onDate: (day) => post({ type: "date", day }),
      // …
    });
  },
  set(markdown) { if (editor && editor.getMarkdown() !== markdown) editor.setMarkdown(markdown); },
};
```

```swift
web?.evaluateJavaScript("MNHost.\(function)(...\(list))")
```

In the extension, the panel mounts the same `MNEditor` and wires the same callbacks to native messaging instead. The
built files are committed, because the extension loads straight from the repo.

Features built once show up in both places. Recent ones:

- **#tags**, highlighted with a ProseMirror decoration; ⌘-click searches the tag.
- **Dates**: typing `@` opens a Notion-style menu (Today, Tomorrow, the coming week, "Next <weekday>", Pick a date…,
  filtered as you type), and `@today` or `@fri` followed by a space turns into a real date. Dated lines show on the
  calendar; checklist lines become tasks you can tick there.
- **A ⋮⋮ drag handle** on every block and list item. I wrote it as a small ProseMirror plugin instead of using
  `@tiptap/extension-drag-handle`, which pulled in collaboration (Yjs) peers, and because ProseMirror's default drop
  point put dropped blocks inside list items.

Tags and dates are parsed from the Markdown text, not stored in columns, so they needed no schema change and sync for
free.

## 9. The knowledge graph: Canvas and a tiny force simulation

The graph view is Obsidian-flavoured: a dot per note, a hub per app or site and per #tag, and four kinds of edges:
explicit links between notes, note to source, note to tag, and "similar meaning". The last one reuses the search
vectors: a pair counts when the cosine is at least 0.5, and each note keeps at most its three strongest, so the graph
doesn't turn into a hairball.

The layout is a small force simulation modelled on d3-force: repulsion between all nodes, springs along edges (stiffer
for explicit links, loosest for similarity), a gentle pull to the center, velocity damping, and an `alpha` that cools
toward zero so it always comes to rest:

```swift
static let alphaDecay = 1 - pow(alphaMin, 1.0 / 300)  // ~300 steps (5 s at 60 fps) from hot to rest
```

Like d3, a spring is softer on busy nodes and the busier end moves less, so hubs stay put. New nodes start on a
sunflower spiral, which spreads them evenly without randomness, so the same notes give the same picture.

Drawing is SwiftUI `Canvas` inside a `TimelineView` that pauses once the layout settles, so a finished graph costs
nothing:

```swift
TimelineView(.animation(paused: layout.isSettled)) { timeline in
    Canvas { ctx, size in draw(&ctx, size) } symbols: {
        ForEach(graph?.nodes.filter { $0.isHub && !$0.isTag } ?? []) { NoteIcon(note: $0.note, size: 40).tag($0.id) }
    }
    .onChange(of: timeline.date) { tick() }
}
```

App and site icons go in as Canvas symbols. Dragging a node pins it and re-warms the simulation so the rest follow.
Since a canvas is invisible to VoiceOver, an accessible list of every node and its connections sits behind it.

Repulsion is O(n²):

```swift
// shortcut: O(n²) repulsion is fine for a few hundred notes; use a Barnes-Hut quadtree beyond ~1,000.
```

## How it was built

I leaned on Claude Code heavily, and it wrote much of this code. The git history spans two days, October 27 and 28,
2026. That speed is mostly the AI's typing; the decisions were the slow part.

What kept it from becoming a pile of plausible code:

- **A decision log.** `docs/DECISIONS.md` has an entry for every choice: what was decided, why, what was rejected,
  who decided (me or the agent), and whether it's settled or only proposed. When I came back to something a day
  later, the "why" was there.
- **Measuring before choosing.** The embedding benchmark above, the Playwright focus test, the CPU fix: each started
  from a number, not a guess.
- **Tests at the seams.** `swift test` covers the title parser, tags, dates, the graph and the sync store;
  `scripts/test_host.py` drives the native host like Chrome does; the editor has round-trip tests in happy-dom.
- **Parallel agents for the redesign.** The Apple Notes–style redesign was four agents in separate git worktrees
  (main window, overlay, browser panel, graph), each following a vendored UI review skill for macOS.

## Limits and what doesn't work yet

- **Places are names, not ids.** Renaming a Slack channel starts a new place, and NoteAnywhere can't deep-link into
  a channel.
- **Only WhatsApp gets the inside-the-window treatment.** Other apps whose titles say nothing stay app-level until
  someone adds them to the table.
- **Pages that re-focus on every blur** can still pull focus from the browser panel.
- **Chrome and Brave only.** The native host is registered for those two; other Chromium browsers would need their
  own manifest.
- **Apple Intelligence needs macOS 26** and a supported Mac. The rest runs on macOS 15.
- **Sync is not end-to-end encrypted**, and the sequence cursor has the edge case above. Sync is optional; everything
  else works without it.
- **SPA navigation is polled** once a second in the content script, and native host replies are capped at 1 MB by
  Chrome, which text notes on one page won't reach.
- **Not shipped yet:** the iPhone app (with Share and Safari extensions), locked notes (password-encrypted, Touch
  ID) and iCloud sync. The first two are in progress.

## Try it

- Code: https://github.com/Vishwas3000/NoteAnywhere (GPL-3.0)
- Mac app (notarized DMG): https://github.com/Vishwas3000/NoteAnywhere/releases/latest
- Chrome/Brave extension: {{CHROME_WEB_STORE_URL}}
- What it reads and stores: [PRIVACY.md](https://github.com/Vishwas3000/NoteAnywhere/blob/main/PRIVACY.md)

If you try it, I'd love to hear which apps' titles it gets wrong. That's the part that improves fastest with more
eyes.
