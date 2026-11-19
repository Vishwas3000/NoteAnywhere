# Decisions

| ID | Decision | Who | Status |
|----|----------|-----|--------|
| D1 | Native SwiftUI app, built with SwiftPM + a bundling script | Claude | Proposed |
| D2 | Store notes locally as one JSON file per note; cloud later | User | Superseded by D18 |
| D3 | Browser ↔ app bridge via Chrome Native Messaging, same binary as host | Claude | Proposed |
| D4 | Overlay opens automatically when the app/tab has notes | User | Decided |
| D5 | Website notes match a URL prefix; user picks "this site" or "this page" | User | Superseded by D19 |
| D6 | Support Chrome and Brave | User | Decided |
| D7 | Extension UX details (see entry) | Claude (subagent) | Proposed |
| D8 | Keep the extension for website notes vs. reading the tab URL via AppleScript | User | Pending |
| D9 | Calendar keeps one snapshot per note per edited day | User | Decided |
| D10 | Semantic search with all-MiniLM-L6-v2 (+ keyword), not Apple's built-in embeddings | User + measured | Decided |
| D11 | One shared TipTap web editor for the Mac app and browser overlay; notes stored as Markdown | User | Decided |
| D12 | Apple Notes feature set: scope and phases in ROADMAP.md | User | Decided |
| D13 | Sync backend for iPhone: decide later; keep storage sync-ready | User | Pending |
| D14 | Search UX: ⌥⇧Space popup, hybrid scoring, host embeds only the query | Claude | Proposed |
| D15 | Calendar layout details (subagent) | Claude (subagent) | Proposed |
| D16 | Browser search UX details (subagent) | Claude (subagent) | Proposed |
| D17 | Browser overlay runs in an isolated extension frame | User | Decided |
| D18 | One SQLite database (WAL) replaces the JSON files | User | Decided |
| D19 | A page shows its own notes plus notes of pages under it, not its parents | User | Decided |
| D20 | One "+ New note" button, always for the current page | User | Decided |
| D21 | Shared editor: TipTap 3.32 IIFE bundle, Markdown storage | Claude (subagent) | Proposed |
| D22 | UI review (ui-review-tahoe skill) fixes applied | User asked; Claude | Proposed |
| D23 | App notes track the window: channel/DM, project/file, … from the front window title (Accessibility) | User | Decided |

## D1 — Native SwiftUI app via SwiftPM (2026-10-27)
- **Why:** native floating panels (`NSPanel`, non-activating, over full-screen apps) and frontmost-app tracking
  (`NSWorkspace`) need AppKit; SwiftPM avoids a hand-maintained Xcode project.
- **Rejected:** Electron/Tauri (heavier, weaker always-on-top/full-screen panel control); Xcode project (pbxproj churn).
- **Status:** Proposed.

## D2 — Local files, one JSON per note (2026-10-27)
- **Why:** user chose "local for now, cloud later". One file per note lets the app and the browser host write
  concurrently without clobbering each other; `id` + `updatedAt` on every note are what a later cloud sync needs.
- **Rejected:** a single notes.json (concurrent writers lose edits); SQLite (more code for no current gain).
- **Status:** Decided (user). Cloud sync not started.

## D3 — Native Messaging, same binary as host (2026-10-27)
- **Why:** browser extensions can't touch the filesystem. Native Messaging only accepts the one extension id
  listed in the host manifest, and Chrome launches the host on demand, so it works when the app is closed.
  `manifest.json` carries a fixed `key` so the unpacked extension id is stable (`fmjimldgmehkakonbffiaacmpijhajop`).
- **Rejected:** a localhost HTTP server in the app (only works while the app runs; any local process or page could
  try to reach it); a separate host executable (an extra target for the same store code).
- **Status:** Proposed.

## D4 — Auto-show overlay (2026-10-27)
- **Why:** user's choice. With no notes, nothing shows until toggled (menu bar / extension icon / ⌥⇧N).
- **Status:** Decided (user).

## D5 — URL prefix matching (2026-10-27)
- **Why:** user's choice. A target matches if the URL equals it or continues with "/", so `github.com` covers the
  site but not `github.company.com`. `www.`, query and hash are ignored.
- **Status:** Decided (user).

## D6 — Chrome + Brave (2026-10-27)
- **Why:** user's choice. `install.sh` writes the host manifest into each browser that's installed.
- **Status:** Decided (user).

## D7 — Extension UX details (2026-10-27)
Made by the subagent that wrote the extension:
- New note ids come from `background.js` — `crypto.randomUUID()` doesn't exist on http:// pages. (Rejected: id in content script.)
- Refreshing on tab focus skips while a textarea has focus, so edits in progress aren't overwritten.
- Closing the overlay sticks until the next navigation or toggle. (Rejected: reopen on every tab switch.)
- Deleting a note that has text asks for confirmation; empty notes delete immediately.
- Errors (e.g. app not installed) don't pop up an overlay on page load; they show when you open it.
- **Status:** Proposed.

## D8 — Extension vs. AppleScript tab URL (2026-10-27)
- **Question from the user:** "are we gonna use extension for this".
- **Option:** the Mac app reads the active tab URL from Chrome/Brave via AppleScript and shows website notes in the
  native panel. Pros: no extension. Cons: macOS Automation permission prompt, ~1s polling, panel floats over the
  window rather than inside the page.
- **Current:** extension (built). **Status:** Pending the user's call.

## D9 — Daily snapshots for the calendar (2026-10-27)
- **Why:** user chose "days edited + snapshot". Every save overwrites `history/<id>/<yyyy-MM-dd>.json`, so each
  day keeps that note's last version. Deleting a note deletes its history too (Claude's call: deleted means gone).
- **Rejected:** dates only (can't show what a note said that day); created/updated only (≤2 days per note).
- **Status:** Decided (user); delete-removes-history is Proposed.

## D10 — MiniLM embeddings for search (2026-10-27)
- **Measured** on 8 sample notes × 7 paraphrased queries (top-1 hit): Apple `NLEmbedding.sentenceEmbedding` 2/7,
  Apple `NLContextualEmbedding` mean-pooled 2/7, all-MiniLM-L6-v2 6/7, bge-small-en-v1.5 6/7, multilingual-e5-small 6/7.
- **Decision:** all-MiniLM-L6-v2 (23M params, ~90 MB one-time download), plus keyword matching so exact words
  (and non-English text) still hit. Run in Swift via the `swift-embeddings` package (MLTensor, macOS 15+).
- **Rejected:** Apple built-in (too weak); e5-small (5× bigger, only needed for non-English meaning search); Ollama (must run separately).
- **Status:** Decided (user picked MiniLM after the numbers). Dependency approved by the user 2026-10-28.

## D11 — Shared web editor, Markdown storage (2026-10-27)
- **Why:** tables, checklists, link cards, sketches and audio need a real rich-text editor; building it once
  (TipTap) and running it in both the Mac app's WebView and the browser overlay keeps them identical.
  Markdown keeps notes readable, searchable, exportable and syncable.
- **Rejected:** native AppKit editor (much more custom text-system work, and the browser would need a second editor).
- **Status:** Decided (user).

## D12 — Apple Notes features in scope (2026-10-27)
- **Chosen by the user:** folders, pins, #tags; formatting, checklists, tables, links between notes; images & files,
  sketches, audio + transcript, scan from iPhone, Notion-style web link previews; export & share, Quick Note hotkey,
  iPhone app + sync. **Not chosen:** Recently Deleted, locked notes.
- **Status:** Decided (user). Order is in ROADMAP.md (Claude's proposal).

## D13 — Sync backend (2026-10-27)
- **Status:** Pending. User: decide later. Options on the table: CloudKit (needs Apple Developer account), Supabase.

## D14 — Search UX and scoring (2026-10-28)
- Global hotkey **⌥⇧Space** (Carbon, no Accessibility permission). Rejected ⌥⇧N: it's the browser overlay's shortcut.
- Score = cosine similarity + 0.5 × (share of query words found). Results need cosine > 0.25 or a keyword hit.
  Measured through the host: 6/7 top-1 on the benchmark set, ~0.4 s per browser search (the host loads the model per call).
- The app keeps `embeddings.json` up to date (2 s after typing stops); the browser host only reads it and embeds the query.
- Results expand into an editor in place (popup and overlay) instead of opening the main window. Popup: superseded by D60.
- **Status:** Proposed.

## D15 — Calendar layout details (2026-10-28, subagent)
- Month grid always 6 rows, cells stretch; cells show first 3 edits that day (earliest first) + "+N more".
- Cells show the note's first line (falls back to app/site name); clicking a day opens the Day view.
- Filter keyed by "kind:target", named by the latest label (page titles change, the key doesn't).
- **Status:** Proposed.

## D16 — Browser search UX details (2026-10-28, subagent)
- Search box sits in the panel body (hidden when collapsed). Website results open the site in a new tab;
  app results expand inline. Keystrokes inside the overlay don't reach the page's shortcuts.
- **Status:** Proposed.

## D17 — Browser overlay in an isolated extension frame (2026-10-28)
- **Why:** the user's typing went into the site's own text box on several sites. The overlay now lives in
  `overlay.html` inside an extension iframe, so page scripts never see its keystrokes or styles; `content.js` only
  places the frame and tracks the URL. Page context reaches the frame via extension messaging, which the page can't forge.
- **Measured** (Chromium + Playwright, scratch test): a page that redirects every keystroke to its own box no longer
  gets the overlay's typing (pass 5/5). A page that re-focuses its box on *every* blur still steals focus (fail);
  a page-side fix isn't possible because the page can't see the pointer enter the frame. Accepted as a known limit.
- **Also:** delete needs a second click (confirm() is blocked in cross-origin frames).
- **Rejected:** a key/focus guard script in the page (weaker, and the phase-2 editor needs the frame anyway).
- **Status:** Decided (user).

## D18 — SQLite storage (2026-10-28)
- **Why:** user asked for a better-designed database and picked SQLite. One file `memorynotes.sqlite`, WAL + busy_timeout
  so the app and the short-lived browser host can both write. Tables: notes (soft delete via deleted_at, for future sync),
  snapshots, embeddings (Float32 BLOB), icons, plus empty folders/tags/links/attachments for phases 3–4.
- Old JSON files are imported once and renamed `*.imported` (never deleted). Changes are announced across processes with
  `notify_post("com.memorynotes.changed")`. A save never revives a deleted note, and the browser can't take over an app note's id.
- **Rejected:** keep JSON files + an index (every later feature would bolt on its own file).
- **Status:** Decided (user); details by the subagent are Proposed.

## D19 — Parent pages see child notes (2026-10-28)
- **Why:** user: "parent should be able to see its child". `list(url)` returns notes whose target equals the page or
  sits under it (indexed range query `[p/, p0)`), and no longer notes from parent pages. Supersedes D5.
- **Status:** Decided (user chose "only this page and below").

## D20 — Single "+ New note" button (2026-10-28)
- **Why:** user: remove "This site"/"This page"; new notes always target the current page. Child-page notes in the
  overlay show a "↳ /path" link that opens that page.
- **Status:** Decided (user).

## D21 — Shared editor build (2026-10-28, subagent)
- TipTap 3.32.0 (pinned) built by Vite into one classic script + CSS (505 kB / 158 kB gzip), loaded by `<script src>`
  in both the extension frame and the app's WKWebView. Markdown via @tiptap/markdown. `note://<id>` links call back to
  the host. Built files are committed because the extension loads straight from the repo. 14 round-trip/list tests in happy-dom.
- Lists: Enter continues and renumbers, Enter on an empty item exits, Tab/⇧Tab indent (user request).
- **Rejected:** ES modules (module loading setup in two hosts); a custom link mark.
- **Status:** Proposed.

## D22 — UI review fixes (2026-10-28)
- Review by an agent following the vendored `ui-review-tahoe` skill; all 12 findings applied: root NavigationSplitView with
  a Notes/Calendar segmented picker, `.searchable` sidebar, ⌘N/⌘F/⌘1/⌘2/⌘⌫ commands, context menus, ContentUnavailableView
  empty states, glass/material floating panels, keyboard navigation in the search popup, confirmation before deleting,
  VoiceOver labels, calendar controls in the toolbar (⌘←/⌘T/⌘→), Help ▸ Keyboard Shortcuts window (user request).
- ⌘⌫ always confirms, because it also means "delete to line start" while typing.
- **Status:** Proposed.

## D23 — Notes per window context, for every app (2026-10-28)
- **Why:** user wants Slack notes tied to the channel/DM they were written in, for every app. The front window title
  is read through the Accessibility API (notified on window/title change, no polling) and cleaned into a broad→narrow
  path: "Alex Rivera (DM) - Acme - 8 new items - Slack" → Slack › Acme › Alex Rivera (DM). App notes target
  "bundle.id/Acme/Alex Rivera (DM)"; same parent-sees-children rule as web pages (D19).
- Cleaning drops the app's own name, unread counts ("8 new items", "(3)"), unsaved dots; "/" inside names is escaped.
  Website notes show "host › cleaned page title" the same way (Slack web → app.slack.com › Acme › DM).
- **Limits:** desktop titles give names, not IDs, so renaming a channel starts a new context and we can't deep-link
  into the exact channel. Without the permission, notes stay app-level. The ad-hoc signed dev build changes signature
  on every install, so macOS may ask to re-allow Accessibility after updates (fix later: a stable signing identity).
- **Rejected:** Screen Recording permission (scarier prompt, needs polling); Slack-only or hand-tuned per-app parsers (user chose every app).
- **Status:** Decided (user). Parser covered by `swift test` (Slack, VS Code, Xcode, browsers, counts, "/").

## D24 — ⌥⇧M shows/hides the overlay from any app (2026-10-28)
- **Why:** user wants one shortcut to show or hide notes in any app; before, only the menu-bar item did it.
- Global Carbon hotkey (no extra permission), same mechanism as ⌥⇧Space, now shared in `HotKeys`. Toggles the overlay
  for the app/context in front, so "New Note for …" is one shortcut away even where no notes exist yet.
- **Rejected:** ⌥⇧N, the browser extension's key; a global hotkey would swallow it in Chrome/Brave.
- **Status:** Decided (user asked; key chosen by Claude, easy to change).

## D25 — Panels open on the mouse pointer's screen (2026-10-28)
- **Why:** multiple displays. User chose the mouse pointer's screen over the front window's screen (needs no AX
  window geometry) and over a fixed position.
- Overlay keeps its offset from the top-right corner when it moves screens, clamped to fit; ⌥⇧Space popup centers there.
- **Status:** Decided (user). Geometry covered by `swift test`.

## D26 — Sign with a real certificate so Accessibility sticks (2026-10-28)
- **Why:** user saw the Accessibility prompt again and again although it was allowed. Ad-hoc signing makes the
  designated requirement a cdhash, which changes on every build, so macOS treated each install as a new app.
- `install.sh` signs with the first valid Apple Development certificate (override: `MEMORYNOTES_SIGN_ID`), so the
  requirement is identifier + certificate and survives rebuilds. Falls back to ad-hoc, with a warning, when there is none.
- **Rejected:** a self-signed certificate (extra keychain setup; a valid Apple Development identity already exists).
- **Status:** Decided (Claude, fixing a reported bug). One last grant was needed after switching.

## D27 — Apple Notes–style redesign, guided by ui-review-tahoe (2026-10-28)
- **Why:** user found the UI "not that great". Chose the Apple Notes feel (over Raycast/Linear or Notion), date-grouped
  sidebar (over by-source or Apps/Websites), and all four surfaces. Built by four parallel agents in worktrees, each
  applying the vendored `ui-review-tahoe` skill (user: "use the skill").
- Shared: Markdown-free `Note.title`/`preview`; editor with icon toolbar, round yellow checkboxes, 15 px + title line in
  the main window (only when the note starts with a line or heading), fit-to-content editors in panels; one accent
  (`Color.notesAccent`, #c78a00 light / #ffd60a dark).
- Main window: Today / Yesterday / Previous 7 Days / Previous 30 Days / Month Year; rows title → time + preview → source;
  source chip + "Edited …"; address field only while empty or via Edit Address…; last tab remembered (`windowMode`).
  Day view rows open the note instead of showing full text (agent's call, easy to revert).
- Overlay: header with search/+ buttons, note cards newest first with hover actions; search popup with Notes rows and a key-hint footer.
- **Status:** Decided (user chose direction); visuals of main window checked by screenshot, panels not yet.

## D28 — Apple Intelligence (2026-10-28)
- **Why:** user asked to use Apple Intelligence for improving text and grammar; chose all four options.
- System Writing Tools in the app's editors (`writingToolsBehavior = .complete`). A ✨ menu in the shared editor (Fix
  Spelling & Grammar, Make Clearer, Make Shorter, Turn into Checklist, Add Title) runs Apple's on-device Foundation Models
  model; selection or whole note; one undoable step; refuses to apply if the note changed meanwhile. The browser asks
  the native host (`op: "ai"`), so it runs on the Mac too. Suggested title + tags are stored per note version
  (`suggestions` table, schema v2), apart from the user's own #tags.
- **Rejected:** cloud LLMs (privacy, cost; on-device is free and good enough for rewrites).
- **Status:** Decided (user). Proofread verified end to end through the host.

## D29 — Live updates app → browser (2026-10-28)
- **Why:** user wants edits to show both ways. Browser → app was already live (Darwin notify); app → browser only on tab focus.
- The extension keeps one `connectNative` port open; the host answers `op: "watch"` by streaming `{event: "changed"}`
  on every save (any process). Background debounces 250 ms and broadcasts `mn:changed`; visible overlays reload,
  never replacing an editor that has focus.
- **Status:** Decided (Claude). Host side covered by `scripts/test_host.py`.

## D30 — Conversation from inside the window for apps whose title doesn't name it (2026-10-28)
- **Why:** WhatsApp's window title is only "WhatsApp", so notes couldn't follow the open chat.
- Per-app table of the accessibility identifier that names the open conversation (WhatsApp: the chat header button).
  Read only that element; message lists are skipped. No notification fires on chat switch, so it's checked once a
  second while such an app is in front. Bidi marks are stripped and a title that only names the app adds no level.
- Narrows D23's "no per-app parsers": titles stay generic; this table is only for apps whose titles carry nothing.
- **Status:** Decided (Claude, fixing a user report). Covered by `swift test`.

## D31 — Sync through Supabase (2026-10-28)
- **Why:** an iPhone app needs the notes. User chose Supabase (over iCloud/CloudKit and same-Wi-Fi sync).
- Each device keeps its SQLite database; cloud tables `notes` and `snapshots` mirror it with RLS per user. A trigger
  enforces last-writer-wins on `updated_at`, keeps tombstones deleted and stamps a `seq` used as the pull cursor;
  Realtime on `notes` for live updates. Project "MemoryNotes" (ref strhaqnvxtpmlvcwkkne). Migration in `supabase/migrations`.
- **Status:** Decided (user). Schema written; applying it needs the user's go-ahead (auto mode blocked the push).

## D32 — Obsidian-style #tags (2026-10-28)
- **Why:** user wants to tag like Obsidian so notes with the same tag connect on the map.
- A tag is `#word` anywhere in the text: needs a letter, may nest (`#project/notes`), case-insensitive; not inside code,
  link targets or headings. Parsed from the text (`Note.tags`), not stored, so sync and the browser need nothing new.
- Graph: a "#" hub per tag, notes joined to their tags, nested tags to their parent; a Tags switch (hubs that are off
  aren't built). Editor highlights tags; ⌘-click searches the tag. Searching `#tag` anywhere (main window, ⌥⇧Space,
  overlays, browser) lists exactly the tagged notes. Sidebar has a Tags section with counts.
- **Rejected:** the unused `tags` table (would need syncing; parsing is cheap); plain click on a tag (it would steal clicks meant for editing).
- **Status:** Decided (Claude, Obsidian semantics as asked).

## D33 — The app/website is optional (2026-10-28)
- **Why:** user: "the app name/website is not optional, make it optional".
- ⌘N makes a plain note (no source) and the editor takes the cursor; ⇧⌘N / + menu still make website or app notes.
  A note without a source can get one later ("Add Website") and lose it ("Remove Website"). Rows hide the source line.
- Stored as a website note with an empty target, which already existed, so no local or Supabase migration; the
  browser still can't save notes without a page, and empty targets never match a page or form a graph hub.
- **Status:** Decided (Claude, as asked).

## D34 — Notion-style block drag and drop (2026-10-28)
- **Why:** user wants to rearrange like Notion.
- A ⋮⋮ handle appears left of the block under the pointer (list/checklist item, else the top-level block: paragraph,
  heading, quote, code, table). Dragging drops it before/after the block under the pointer, never inside it; list
  items move between list items. A yellow line shows the spot. ⌘⇧↑/↓ moves the current block (keyboard + VoiceOver path).
- Own ~100-line ProseMirror plugin in the shared editor (app, overlays, browser, iPhone).
- **Rejected:** `@tiptap/extension-drag-handle` (pulls in collaboration/Yjs peers); ProseMirror's default drop point
  (dropped blocks inside list items).
- **Status:** Decided (Claude). Real-WebKit drag checked (paragraph above a list; list item reorder); happy-dom tests for ⌘⇧↑/↓.

## D35 — Dates on lines and tasks, shown on the calendar (2026-10-28)
- **Why:** user wants to tag a date in a note so a task shows on that day.
- Written in the text like tags: `@2026-10-30` (Obsidian Tasks' `📅 2026-10-30` also read). Typing `@today`, `@tomorrow`,
  `@yesterday` or a weekday (`@fri`, next one, today included) + space turns into the real date; 📅 in the toolbar
  picks any day. Dates show as chips; ⌘-click opens that day in the calendar.
- Calendar: each dated line appears on its day ("Planned", above edits); checklist lines are tasks with a box that
  ticks the task in the note itself. Invalid dates (2026-02-30) and code are ignored.
- Parsed from text (`Note.dates`), so no schema change; it syncs and works in the browser and on iPhone as is.
- **Rejected:** a due-date column (needs migrations + sync); natural-language parsing of free text (surprising edits).
- **Status:** Decided (Claude). Parser + editor covered by tests; chips checked in WebKit; calendar not yet seen with dated notes.

## D36 — Going public as NoteAnywhere (2026-10-28)
- **Why:** user wants to open-source the app, post about it (Medium, dev.to, Reddit r/macapps, more) and make it easy to try.
- **Decided by the user:** public name **NoteAnywhere**; license **GPL-3.0**; Mac app as a **notarized DMG** (Developer ID,
  team GH5YVSN865); extension on the **Chrome Web Store**.
- Internal identifiers stay (`com.memorynotes.*` bundle id, native host name, `memorynotes://` scheme, data folder) so the
  current install keeps its notes, permission and sync; only user-visible names change.
- Dependencies are MIT (TipTap, swift-embeddings, the vendored ui-review-tahoe skill), compatible with GPL-3.0.
- `install.sh` remembers its signing certificate in an untracked `.signing-identity`, since with several valid
  certificates keychain order could change it and reset the Accessibility permission.
- **Status:** Decided (user); release engineering and launch copy in progress.

## D38 — Launch copy and privacy policy (2026-10-28, subagent)
- **Why:** D36 needs posts, a store listing and a privacy policy. Written in `launch/` and `PRIVACY.md`, from the code
  on `main`, not from memory: anything not merged (locked notes, iPhone app, iCloud) is listed as coming soon.
- Claims are limited to what was measured: idle CPU ~0%, 37–65 MB, MiniLM ~87 MB, the 8-note × 7-query search test.
  Posts use demo names only (Acme, Sam, weather-app); screenshots come from a separate macOS Demo account, because
  the browser host always opens the default database, so `MEMORYNOTES_DIR` alone would leak real notes.
- PRIVACY.md says plainly that deleted notes stay in the database as tombstones (soft delete, for sync) and that
  sync isn't end-to-end encrypted. The Web Store disclosure declares web history and website content (page address
  and title) even though they only reach the app on the same Mac.
- Order: long posts (dev.to, Medium) first so later posts can link them, then Show HN, r/macapps, one subreddit a day,
  Product Hunt last. AI-assisted build disclosed in the dev-facing posts; optional line in r/macapps.
- **Rejected:** one-day blast across every site (no time to answer or fix); a contact email baked in (left as
  `{{CONTACT_EMAIL}}` for the user to choose).
- **Status:** Proposed. Nothing is posted; the user posts.

## D37 — Apple Notes right-click menu: folders, pins, colours, lock (2026-10-28)
- **Why:** user wants Apple Notes' note menu (screenshot) plus colour codes like Chrome's tab groups, and a total count.
- Open Note in New Window, Pin, Lock, New, Duplicate, Share, Move to ▸ folders (New Folder…), Color ▸ (Chrome's nine
  tab-group colours), Delete. Sidebar: Folders (All Notes + folders with counts), Pinned, then dates; count under the title.
- Pins/colours/folders change `updated_at` by +1 ms: enough for newer-wins sync, without moving the note to "Today".
  Folders are tombstoned; their notes go back to All Notes. All of it syncs (local schema v4, Supabase migration 2).
- **Lock** (user chose real encryption over hiding): one notes password; text becomes an AES-GCM envelope keyed by
  PBKDF2-SHA256(password, per-note salt, 310k). Touch ID unlocks via LocalAuthentication + a Keychain copy on this
  device. Locked notes hide title/preview/tags/dates and are skipped by search and the browser.
- **Status:** Decided (user). Shipped: menu, folders, pins, colours, Lock Note / Remove Lock, unlock screen (Touch ID or password), Lock All Notes. Covered by tests (crypto, scrubbing history and vectors, browser exclusion).

## D39 — Supabase sync is end-to-end encrypted (2026-10-28)
- **Why:** user: "make sure when data is stored on Supabase it is encrypted; if the user chooses iCloud, follow the regular route".
- A random 256-bit vault key per account seals each note's text, place (page address / app-chat path) and title, folder
  names and history (AES-GCM, `mne2e:v1:`) before upload. The server stores the key only wrapped by
  PBKDF2(sync passphrase, salt) in `vaults` (RLS). First device creates the passphrase (plain insert, so a racing second
  device can't replace it); others enter it once; the key lives in this device's Keychain. Sync refuses to run without it.
- Visible to the server: ids, times, kind, pin/colour/folder ids, locked flag, account email.
- **Rejected:** server-side encryption only (Supabase could read); reusing the notes (lock) password (different purposes).
- Forgetting the passphrase loses the cloud copy, not local notes. iCloud (when built) uses Apple's own protection.
- **Status:** Decided (user asked). Needs `supabase db push` (migration 3). Covered by a test that rows carry no readable text.

## D40 — No real people or workspaces in the repo (2026-10-28)
- Comments, tests and decisions used a colleague's name, a work Slack workspace and a WhatsApp group from screenshots;
  replaced with demo names before going public. **History rewritten** (user approved): every commit on main scrubbed
  with `git filter-branch` and force-pushed (2026-10-28); a local `backup/pre-rewrite-2026-10-28` branch was kept.

## D41 — iPhone app (2026-10-28, subagent; user chose the scope)
- XcodeGen project in `ios/` (generated `.xcodeproj` not committed); shared Swift files compiled by path, so the Mac
  code needs no `public`. App Group `group.com.memorynotes` is the store for the app, the Share extension and the
  Safari Web Extension. Tabs (Notes / Calendar / Graph / Settings), sidebar on iPad; "+" makes a no-source note.
- The Safari extension reuses `extension/`; Safari kills pages whose extension frame calls `tabs.*`, so the iOS build
  routes those calls through the background page (build fails loudly if the call sites change).
- Locked notes show a placeholder on iPhone for now; MiniLM downloads on the first search.
- **Rejected:** a shared Swift module (`public` everywhere); forking the extension JS.
- **Status:** Decided. Builds and runs in the iOS 26.2 simulator with 4 UI tests (incl. both extensions); not yet on a
  device (needs `DEVELOPMENT_TEAM: GH5YVSN865` and App IDs with the App Group).

## D42 — Google sign-in for sync (2026-10-28)
- **Why:** user asked for Google OAuth.
- Supabase's Google provider; the app opens `/auth/v1/authorize?provider=google&redirect_to=memorynotes://auth-callback`
  in SwiftUI's `webAuthenticationSession` (a secure sheet) and reuses the email link's callback handling. Email link stays.
- Client id/secret live in the Supabase dashboard (and env vars for `config push`), never in the repo.
- End-to-end encryption is unchanged: Google only proves who you are; the sync passphrase still unlocks the notes.
- **Status:** Decided (user asked). Live 2026-11-20. Until then, the button shipped in 0.1.2 failed with "provider is
  not enabled". The user made the Google OAuth client (Web application, project NoteAnywhere, redirect URI
  `https://strhaqnvxtpmlvcwkkne.supabase.co/auth/v1/callback`) and turned the provider on in Supabase. Checked from
  outside: Supabase sends the sign-in to Google with scopes `email profile`, and Google shows its sign-in page, not an
  error. PRIVACY.md and the README say what Google and the sync server receive.

## D43 — A calendar pop-up for "Pick a date…" and 📅 (2026-10-29)
- **Why:** user asked that "Pick a date…" open a pop-up to choose the date; it showed a plain date field above the note.
- The shared editor draws its own month calendar at the cursor (below the line, above it near the window's end):
  arrows move a day or week, PageUp/PageDown a month, Return or a click picks, Esc closes. One version for the Mac
  app, the browser panel and iPhone; an ARIA grid for VoiceOver.
- Weeks start on Sunday in every locale for now.
- **Rejected:** `<input type="date">` with `showPicker()` (it showed a field, not a calendar, in the app's WebView);
  a native NSDatePicker over the bridge (the browser panel and iPhone would each need their own).
- **Status:** Decided (user asked). Editor test covers open, keys, pick and Esc.

## D44 — The note's scroll bar at the window's edge (2026-10-29)
- **Why:** user: "the scroll bar of the notes is not to the edge". The editor's web view was padded 40 pt in, so its
  scroll bar sat inside the text column.
- The web view now fills the pane (main window and a note's own window); with `page: true` the page centres the text
  in the same 720 px column with 40 px sides. Content-sized editors (panel cards, search) are unchanged.
- **Status:** Decided (user asked). A note in its own window now uses the same column (was 32 pt sides, no maximum).

## D45 — A bigger note on the app icon (2026-10-29)
- **Why:** user asked for the icon's note to be bigger. The tile was already the system size (checked against Notes and
  Calendar as macOS draws them), so only the note grew: ×1.22, about 60% of the tile. Extension icons redrawn from it.
- **Status:** Decided (user asked).

## D46 — Fast calendar, and timing every view switch (2026-10-29)
- **Why:** user: switching to Calendar was slow; asked to track compute during transitions like it.
- **Cause, measured** (release build): the month view re-read every note's dated lines once per day cell (43 times a
  draw), and Swift Regex costs ~0.1 ms per line. 5 notes: 0.47 s a draw; 200 notes: 18 s.
- **Fix:** dated lines are read once per draw; the tag, date and plain-text parsers skip lines that lack the character
  their patterns need (`#`, `@`/📅, Markdown marks), so the result is identical; a title or preview reads only its first
  lines. Dates for 5 notes now take ~8 ms per draw.
- **Tracking:** `Perf` times each Notes/Calendar/Graph switch from the click until the new view is committed: wall
  time, CPU time (all threads) and memory, as a log line (`log stream --predicate 'subsystem ==
  "com.memorynotes.app" AND category == "perf"'`) and an interval in Instruments' Points of Interest.
- **Rejected:** caching parsed dates on the model (more state to keep right; not needed at this size); an on-screen
  HUD (the log and Instruments already show it).
- **Status:** Decided. Switch timings from the real app still to be read once the user switches views.

## D47 — Colour labels as a strip at the note's edge (2026-10-29)
- **Why:** user asked for a strip instead of the dot. The sidebar row (Mac) and list row (iPhone) draw a 4 pt
  capsule in the row's leading margin, like the floating panel's cards and Chrome's tab groups; VoiceOver still reads
  "<Color> label".
- **Status:** Decided (user asked).

## D48 — Dates in notes in the user's format (2026-10-29)
- **Why:** user: "change the date format to day, month, year, or in settings I should be able to choose".
- Notes keep storing `@2026-10-30` (the calendar, sync, Obsidian and sorting depend on it). Only the display changes:
  the editor's chips (Mac, panel, extension, iPhone) and note previews show the day in Settings ▸ General ▸ "Dates in
  notes": Automatic (the region's numeric date with a 4-digit year; 30/10/2026 for en_IN), Day/Month/Year,
  Month/Day/Year or Year-Month-Day.
- A chip is a widget over the source text, which is shrunk to nothing; with the caret inside, the chip shows
  `@2026-10-30` for editing, like Obsidian's live preview. The extension gets the pattern with each `list` reply.
- **Rejected:** storing dates in the chosen format (breaks parsing, sync between differently set devices, Obsidian);
  an atomic date node in the editor (a custom Markdown node for little gain).
- Not done: typing `@30/10/2026` isn't recognised; `@today`, the @ menu and the calendar pop-up are the ways in.
- **Status:** Decided (user asked). Mac Settings gained a General tab; the menu's "Sync Settings…" is now "Settings…".

## D49 — A "/" block menu, like Notion's (2026-10-29)
- **Why:** user asked for Notion-style "/" commands, only the most used, plus "/break page" (chosen: a divider line).
- "/" at a line's start or after a space opens: Text, Heading 1–3, Bulleted list, Numbered list, To-do list, Quote,
  Code, Break page (a `---` divider; also found by "divider", "line", "hr"), Table, Date (the calendar pop-up).
  Typing filters by name or keyword; Return/Tab applies; Esc dismisses. Each row shows its Markdown shortcut.
- The "@" date menu and the "/" menu now share one popup (`suggestMenu`), so they behave the same.
- **Rejected:** a page break for print/PDF (user picked the divider); a long Notion-sized list (user: most used only).
- **Status:** Decided (user asked). Editor tests cover filter, apply, divider, to-do, Esc and no menu inside URLs.

## D50 — An MCP server for Claude, Codex and Gemini (2026-10-29)
- **Why:** user wants Claude, Codex and Gemini sessions to work with their notes; chose "read + full edit, no delete".
- The app's own binary runs as a stdio MCP server (`MemoryNotes --mcp`), like the browser host: no extra install, the
  same NoteStore, search and save path, so edits sync, get a day snapshot and show in the open app at once.
- Dual-era: the 2026-07-28 protocol (`_meta` per request, `server/discover`) and the older `initialize` handshake
  (2024-11-05 to 2025-11-25) that clients still speak.
- 11 tools: search, list, get, tasks, tags, folders, create, append, replace (refused if the note changed since it was
  read; the stamp is checked whether sent as a number, float or string, and junk is refused), update
  pin/colour/folder, tick a task. Summaries by default, full text only from get_note.
- No delete tool. Locked notes' text is never returned or written; pin, colour and folder still work, as in the app.
- Registered for the user in Claude Code (user scope), Codex, Claude Desktop and Gemini CLI (user settings; Gemini
  loads it only in trusted folders). Config backups were kept outside the repo.
- **Rejected:** the official Swift MCP SDK (a dependency for ~400 lines of JSON-RPC); a separate server process or
  HTTP transport (stdio is what all four clients launch); exposing notes as MCP resources (tools work in every client,
  resources don't).
- Built by a parallel agent; the parent reviewed it and fixed the stale-stamp check, which skipped string or float
  stamps.
- **Status:** Decided (user chose the access level and clients). Tested over stdio (scripts/test_mcp.py) and
  `claude mcp list` shows it connected; not yet used in a real conversation.

## D51 — Pages from highlighted text, hover previews and a side peek (2026-10-29)
- **Why:** user: highlight a question, "add a page" for the answer found later; hover shows a quick description and
  opening shows the details, like VS Code's hover and go-to-definition.
- On highlighted text (one line), a small menu offers **Add page** (⌘⌥P): a plain note titled with the highlight, in
  the same folder, with a ↖ link back; the highlight becomes a `note://` link to it. **Link to a note…** (⌘⇧K)
  searches titles and first lines and links the highlight to the pick. Apple Intelligence's Writing Tools stay as they
  were.
- Hovering a `note://` link shows its title and first lines (after 350 ms); clicking it opens the page in a resizable
  side peek beside the note (main window), with Open as Main Note and Close. Links in the peek replace the peek.
  Elsewhere (floating panel, own window) a click opens it in the main window as before.
- Pages are ordinary notes (user's choice): in the list, search and graph, linked both ways.
- The `↖ [note](note://…)` line is left out of previews (hover card, sidebar row, link search, MCP summaries): user
  didn't want it in the hover card; it's for getting back, not the page's content. It stays in the note itself.
- The editor bridge's request/reply became generic (`ask`/`reply`); `aiDone` stays as an alias for the iPhone app.
- **Not done:** the browser extension and iPhone don't get the menu or hover cards yet (their hosts would need the
  same three requests).
- **Rejected:** opening pages by navigating away or in a new window (user chose the side peek); nested sub-pages
  hidden from the list (user chose normal notes).
- **Status:** Decided (user chose the peek, menu items and visibility). Editor tests cover add, link and hover; a
  Swift test covers the page text.

## D52 — Maths in notes (2026-10-29)
- **Why:** user pasted `\(Q = XW_Q\)` (an AI chat's LaTeX) and it wasn't formatted. Worse, Markdown read `\(` as an
  escaped bracket, so reopening a note turned it into `(Q = XW_Q)`, and typed text saved as `\\(…\\)` / `XW\_Q`.
- TipTap's maths nodes (`@tiptap/extension-mathematics` 3.32.0, KaTeX 0.16.47) with our own Markdown tokenizers:
  `$…$` and `\(…\)` inline, `$$…$$` and `\[…\]` on a line of their own; saved as `$…$` / `$$…$$` (Obsidian's form). The
  LaTeX is kept exactly; no Markdown escaping touches it.
- A single `$` follows pandoc's rule (opens before a non-space, closes after one, not before a digit): "$5 and $10" and
  `$HOME` stay text.
- Text that reads as maths (pasted, typed, or saved before this, escaped) becomes a formula once the caret leaves it;
  clicking a formula turns it back into its source, like the date chips.
- KaTeX renders MathML only, which WebKit and Chrome draw natively: no KaTeX CSS or fonts to ship. The bundle grew
  from 521 to 794 KB.
- **Rejected:** KaTeX's HTML output (needs ~20 font files copied into the app, extension and iPhone); Temml (smaller,
  but TipTap's nodes call KaTeX); rendering math as decorations over text (Markdown would still mangle `_` and `\`).
- **Status:** Decided (user reported it). Editor tests cover parsing, saving, prices, legacy escaped text, typing and
  click-to-edit; checked in WebKit, light and dark.

## D53 — Images in notes: pasted and dropped, kept by the app, synced encrypted (2026-10-29)
- **Why:** user couldn't paste an image into a note in the browser overlay, and a pasted web image didn't show. Notes had
  no place for image bytes: a screenshot pasted nothing, and "Copy Image" from a page only linked to the site's copy,
  which the extension's page can't load when the site blocks other origins or the link expires (ChatGPT, Slack, Notion).
- **Chosen by the user:** images are files the app keeps, synced end-to-end encrypted ("App files, synced").
- The bytes are files in `images/<id>` next to the database, with a row per image (`images` table, schema v5). A note
  shows one as `![](noteimage:<id>)`. Allowed: PNG, JPEG, GIF, WebP, AVIF, HEIC/HEIF (HEIC shows in WebKit only), up to
  20 MB; checked in the editor and again where the bytes arrive.
- Editor: image files on the clipboard or in a drop go to the host, which answers the source; "Copy Image" keeps the
  bytes, not the site's link. A clipboard that also carries text (Office copies a picture of the cells) pastes as text.
  A failure shows a red notice; an image that can't load shows why in a dashed box instead of vanishing.
- Mac and iPhone serve `noteimage:` to their web views with a WKURLSchemeHandler (`ImageScheme`). The browser asks the
  Mac app (native host ops `addImage`, `image`): replies are capped at 1 MB, so images come in 600 KB pieces and become
  `blob:` URLs, fetched once per panel.
- Sync (decided by Claude's subagent): images go up before the notes that show them, sealed with the vault key
  (AES-GCM, no prefix), into a private Storage bucket `images` at `<user id>/<image id>`; a `public.images` row
  (id, type, created_at, seq) tells other devices to fetch them. The type stays plaintext, like a note's kind. Storage
  policies limit each account to its own folder; nothing deletes. Image rows never change, so seq is set on insert only.
  An image failure never holds up notes: they sync, then "Images didn't sync: …" shows.
- **Known limits:** images are never deleted (follow-up with the "wipe on delete" item); a locked note's images stay
  unencrypted on this device; images inside pasted HTML (copying part of an article) still link to the site.
- **Rejected:** base64 inside the Markdown (a few screenshots pass Chrome's 1 MB host reply cap and the page's notes stop
  loading; bloats search, daily snapshots and MCP replies); the existing `attachments` table (it needs a saved note,
  and one image can be pasted into many notes).
- **Status:** Decided (user). Editor tests, host test (pieces under 1 MB, bad types and ids refused), Swift store and
  vault tests, and a headless Chromium run with the real host: a note's image shows, a pasted screenshot is kept.
  WebKit loads `noteimage:` from the editor's file page. The Supabase migration is written and was checked in a local
  Postgres, and applied to the hosted project on 2026-10-29 (user approved, with 0.1.1); the Storage calls haven't
  run against a real server yet.

## D54 — First release: NoteAnywhere 0.1.0 on GitHub (2026-10-29)

- **Asked by the user:** "can you add the dmg in the github", notarized first.
- Built by `scripts/release.sh` from 087ca14 (tag `v0.1.0`), the last commit before images (D53), whose Supabase
  migration isn't applied yet. Universal (Apple silicon and Intel), macOS 15+, Developer ID signed, notarized and
  stapled; `spctl` accepts the DMG and the app inside, and the downloaded asset matches the local file (SHA-256
  0da4605d…). The release has the DMG only; the extension zip goes to the Chrome Web Store.
- Notarization signs in with an App Store Connect API key (Team key, Developer role) saved as the `NoteAnywhere`
  keychain profile. The app-specific password route failed: the agent's shell has no terminal, so the prompt read an
  empty password (401). The `.p8` lives in `~/.appstoreconnect/private_keys/`, outside the repo.
- **Chosen by the user:** publish now rather than wait for the Web Store id. 0.1.0 only trusts the unpacked development
  extension (`BrowserBridge.devExtensionID`), so the store extension needs a follow-up release with
  `storeExtensionID` set; store review takes days, so that release can be out first.
- **Status:** Done. Published at https://github.com/Vishwas3000/NoteAnywhere/releases/tag/v0.1.0.

## D55 — A welcome window on first launch (2026-10-29)

- **Asked by the user:** show that the app works with the Chrome extension, as "just a simple step" in onboarding.
  There was no onboarding, only an "Allow Accessibility" line in the floating panel.
- **Chosen by the user:** one welcome window (over a hint in the panel), shown once when the main window first appears
  (`welcomeShown`), and again from Help ▸ Welcome to NoteAnywhere. Two steps: Allow Accessibility (ticks itself when
  the app comes back to the front with the permission) and Add the browser extension. Existing installs see it once
  after updating, which is how they hear about the extension.
- "Get the Extension" opens the Web Store page once `BrowserBridge.storeExtensionID` is set; until then the latest
  GitHub release, whose notes explain loading it unpacked.
- **Rejected:** a multi-page tour; detecting that the extension has connected (the host runs in the browser's process,
  so it needs a shared flag; not worth it for a one-time window).
- **Status:** Done. Checked by rendering the view offscreen (light); after installing, the app set `welcomeShown` at launch
  (the window was asked to open). Not yet seen on screen by Claude.

## D56 — Dates with the day and month by name (2026-10-29)

- **Asked by the user:** a section in the date format setting that shows the date, day and month.
- **Chosen by the user:** three more formats in Settings ▸ "Dates in notes", grouped as "With day and month names":
  "Friday, 30 October" (`EEEE, d MMMM`, which adds the year only for other years), "30 October 2026" and
  "Fri, 30 Oct 2026". Notes still store `@2026-10-30`; only the chips change.
- Swift (`DateStyle.format`) and the editor (`formatDay`) share one token rule (E, d, M, y); names are English, like
  the rest of the app.
- **Status:** Done. Swift and editor tests cover each format and the other-year case.

## D57 — Release 0.1.1: images, welcome window, store extension (2026-10-29)

- **Chosen by the user:** everything on main plus the database update, over a store-ID-only release. The images
  migration (D53) was applied to the hosted Supabase project first (`supabase db push`, user approved).
- The app trusts the Web Store extension (`fngldbimlphnokkkkodneojgbdnofjha`). `BrowserBridge.storeListed` stays false
  until Google approves the listing, so "Get the Extension" opens the GitHub release instead of a "not found" page.
- Built from d2f6561 (tag `v0.1.1`); notarized, stapled, universal; the downloaded asset matches (SHA-256 d0bfcbe7…).
  The store is reviewing the 0.1.0 extension zip; the 0.1.1 zip (image paste) goes up as an update after approval.
- **Status:** Done. https://github.com/Vishwas3000/NoteAnywhere/releases/tag/v0.1.1

## D58 — Links open on click or tap (2026-10-30)

- **Reported by the user:** tapping a link in a note didn't open it.
- Cause: web links opened only with ⌘-click, through `window.open`, which the Mac and iPhone editors' WKWebView
  dropped (no `WKUIDelegate`), so in the apps they never opened at all.
- **Chosen by Claude:** a click or tap opens the link in the default browser (Safari or the link's app on iPhone), like
  Apple Notes and Notion; shift-click still extends the selection and ⌘K edits the link. Both web views now hand
  `window.open` to the system. `javascript:`, `data:` and `vbscript:` links never open.
- **Status:** Done. Editor test covers click, shift-click and `javascript:`; a real click in the app not yet tried by Claude.

## D59 — Pasted links as a link, mention or card (2026-10-30)

- **Asked by the user:** preview pasted links, asking each time how to show them, like Notion.
- **Chosen by the user:** on pasting a lone URL, a menu offers Link (selected), Mention (site icon and page title in
  the line) and Card (title, description, site, picture); Enter, Esc or typing keeps the link. The card's picture and
  the icon are downloaded once and kept as note images (D53), synced end-to-end encrypted, so the site never sees the
  note opened and the picture outlives the page.
- **Chosen by Claude:** the host fetches the page (`LinkPreview.swift`, shared by the Mac and iPhone apps); the
  extension asks the Mac app through the native host, so it needs no new site permissions or store re-review.
  Markdown that other apps can read: a mention is `[Title](url "mention noteimage:…")` (a normal link elsewhere), a
  card an Obsidian-style callout `> [!bookmark] [Title](url)` with the description and `![](… "icon") ![](…)` lines.
- **Rejected:** Embed (loads the site in the note on every open: slower, less private); remembering a default instead
  of asking; loading pictures from the site each time.
- Fetching (`LinkPreview.swift`): http/https only, 10 s timeout, 2 MB of the page's `<head>`; Open Graph, then Twitter
  cards, then `<title>`/`description`; apple-touch-icon over the largest `sizes`, SVG icons skipped for `/favicon.ico`;
  pictures up to 5 MB from http, https or data: only, ICO and the like converted to PNG. A page that answers non-2xx,
  or blocks bots (some Cloudflare sites, x.com), says why and stays a link.
- Found on the way: after pasting a screenshot the image stayed selected, so the next keystroke or paste replaced it
  (since D53). The cursor now goes after pasted images.
- **Status:** Done. Editor tests (menu, mention, card, Markdown round-trips, failure message), Swift tests (parsing,
  ICO→PNG, plain text), and `scripts/test_overlay.mjs` in Chromium with the real extension and host: paste a link,
  pick Card, the picture is kept and shows. Live pages checked through the host: react.dev, developer.apple.com,
  GitHub, Wikipedia (no description: it serves none), Hacker News. Not yet tried by hand in the Mac or iPhone app.

## D60 — ⌥⇧Space results open the note in the main window (2026-10-30, subagent)

- **Reported by the user:** clicking a note in the ⌥⇧Space search didn't open it in NoteAnywhere.
- Cause: not broken wiring but D14's choice: a popup result only expanded into an editor in place
  (`SearchResultsView.toggle`), and Return did the same; nothing asked the main window to open.
- **Chosen by the user:** click or Return opens the note in the main window. **By Claude:** the popup sets
  `openRequest`, opens the "notes" window, activates the app and hides itself, like the overlay's "Open in
  NoteAnywhere"; the footer says "↩ Open". The overlay's own search still expands in place (not reported). An open
  request now clears a folder filter that would hide the note's row. Locked notes ask to unlock as usual (NoteEditor).
- **Status:** Done. Builds, tests pass; not tried by hand in the running app (opening from another app, window closed).

## D61 — Date ranges in the calendar (2026-10-30)

- **Asked by the user:** "Rohin Wedding @2026-12-03 - @2026-12-06" should colour the days from the first to the last.
- A line with two dates joined by `-`, `–`, `—` or `to` is a range: it's on every day from the first to the last
  (either order; a same-day "range" is one date). Other dates on the line still count on their own.
- **Chosen by the user:** the bar takes the note's colour label, else a colour of its own picked from the line (no
  pink or yellow: too close to purple and the accent), stable between launches.
- **By Claude:** Mac month view draws a tinted bar running across the cells, rounded at the ends, titled on the first
  day and where a week starts; week and day views tint the row and show "3 Dec – 6 Dec". iPhone month view draws a thin
  bar under the day numbers. Ranges sort first, earliest start first, so a bar mostly keeps its row.
- **Asked by the user (follow-up):** the strip should be continuous in the week view too. Ranges there sit above each
  day's list in rows shared by all seven columns (a range that starts after a row's last one ends joins that row), so
  each strip runs unbroken across the days; grid lines and column dividers now draw under the strips, which are opaque.
- shortcut: a range stops after 366 days; overlapping ranges with different starts can step down a row.
- **Status:** Done. Swift tests (parsing, order, colour); the real Mac calendar rendered offscreen in light and dark
  from demo notes. iPhone builds; its calendar not looked at.

## D62 — Chrome Web Store description names no browsers (2026-11-01)

- **What happened:** the store rejected 0.1.0 (Spam and Placement, "Yellow Argon") for excessive keywords in the
  description: "It works with Chrome, Brave, Edge, Arc, Vivaldi and Chromium." That line was typed in the dashboard;
  the draft in launch/chrome-web-store.md said "Works in Chrome and Brave".
- **By Claude:** the description lists no browsers; the line is now "Needs the NoteAnywhere app on a Mac with macOS 15
  or later." The site's footer, which isn't store metadata, keeps its browser list. Rejected: appealing (the policy
  names exactly this pattern).
- **Asked by the user (follow-up):** bring the rest up to date. The README and the site now say "Chrome and Brave"
  like D6, the privacy policy and the posts (they claimed Edge, Arc and Vivaldi, never tested; the app still registers
  its host with those browsers). The launch checklist's release items are ticked: each was checked in the code.
- **Status:** Draft fixed; the user pastes it into the dashboard and resubmits.

## D63 — Notes can wait for their shortcut; a note you open takes the cursor (2026-11-03)

- **Asked by the user:** some people don't want notes popping up by themselves; they'd open them with a hot key.
- **Chosen by the user:** one switch for both, Settings ▸ General ▸ "Open notes by themselves" (on by default). Off,
  the Mac panel opens only with ⌥⇧M and the browser panel only with ⌥⇧N or the toolbar icon. The extension learns it
  from the host's "list" reply (`autoOpen`), so there's nothing to set in the browser; an older app that doesn't send
  it keeps the old behaviour. An open panel still follows the app in front.
- **Asked by the user:** with WhatsApp in front, ⌥⇧M → search → open a note showed no cursor.
- **By Claude:** the panel never took the keyboard (it's non-activating so opening by itself can't steal typing), and
  an editor only took the cursor when its note was empty. Now ⌥⇧M makes the panel key with the cursor at the end of
  the newest note there; a search result expanded in the panel, and a note opened in the main window (search popup,
  calendar, graph, links), take the cursor too (`NotesModel.focusRequest`). Opening by itself still doesn't take it.
  Locked notes don't ask for it, so no stale request steals focus later.
- **Status:** Done. Extension test covers the switch off (a page with notes stays closed; the icon opens it); Swift
  and editor tests pass. The cursor change is not tried by hand (no synthetic keys or clicks on the user's Mac).

## D64 — "@dec9th" and other month-and-day dates (2026-11-03)

- **Asked by the user:** typing @dec9th should become a date in the chosen format, for people who'd rather type.
- **By Claude:** like `@fri `, a month and day followed by a space becomes `@yyyy-mm-dd` (shown in the Settings
  format): `@dec9th`, `@dec9`, `@dec 9th`, `@9 dec`, `@9thdec`, `@December 25`. It means the next one, today
  included, so `@jan1` in November is next year, the same rule as weekdays. A day that doesn't exist (`@feb30`)
  stays as typed. Only the editor converts; the note still stores ISO dates, so the Swift side needs no change.
- shortcut: no explicit year (`@dec9 2027`); type the ISO date for a past or far-off day.
- **Status:** Done. Editor tests (parsing, typing, impossible days).
- **Asked by the user (follow-up):** "@jan7" didn't turn into a date: it did only on a space, and the @ menu closed as
  soon as a letter matched none of its days, so nothing showed it would. The menu now reads a typed month and day
  ("@jan7", "@dec 9th") and offers that date in full ("Thursday, 7 January 2027"); Return or Tab picks it, a space
  still works. Editor test.
- **Bug (user report):** typing "@" moved the whole note sideways. The menu opened at the caret with nothing keeping
  it inside the editor, so near the right edge it stuck out and the note scrolled to show it; and the menu showed its
  chosen item with scrollIntoView, which scrolls the note too. Now it's kept inside the editor and scrolls only
  itself. The extension test types "@" at a long line's end in the real panel: it failed before (menu at 342 px of
  340) and passes now.
- **Chosen by the user (follow-up):** feedback while typing, the menu following every letter. "@j" lists January,
  June, July (with any day names that match); "@jan" and "@jan " show "January · type the day" (picking it types
  "@jan" and waits); "@jan7" shows the full date; "@7 ma" shows 7 March and 7 May. Rejected: an inline preview after
  the typed text. Editor test steps through each keystroke.

## D65 — Every calendar event in colour; right-click to change it (2026-11-03)

- **Asked by the user:** always colour calendar events so they stand apart from notes merely edited that day, and
  right-click an event to switch its colour.
- **Chosen by the user:** the colour is the note's colour label, so every event in a note takes it and the sidebar
  strip matches; no change to the note's text.
- **By Claude:** in the month view single-day events are tinted pills like the range bars; edited notes stay plain,
  in grey. Week and day views tint their rows and the task circle or calendar glyph. Right-click any event (pill, bar,
  strip, row) → Color, the same menu as the sidebar's (`ColorLabelMenu`). Mac only; the iPhone calendar is unchanged.
- **Superseded in part by D67:** right-click now colours only that event. Month view rendered offscreen from demo
  notes in light and dark. The right-click menu is not tried
  by hand.

## D66 — Android app v1 (2026-11-03, subagent)

- **Chosen by the user:** a native Kotlin + Jetpack Compose app in `android/`, syncing with the Mac and iPhone through
  the same Supabase project and end-to-end encryption. Scope: email-code sign-in, enter or create the sync passphrase,
  list / search / create / edit / delete notes, folders and colour labels shown, locked notes shown as locked
  (read-only), pull on open + pull-to-refresh + push after edits. The editor is a plain Markdown text box. A debug APK
  to sideload. No calendar, graph, widgets, Google sign-in, images or Play Store.
- **By Claude:**
  - applicationId **`com.memorynotes.android`**, not `com.memorynotes.app`: that's already the Mac app's bundle id.
  - Wire format copied from `SyncCloud.swift`: same project URL and publishable key, `auth/v1/otp` + `verify`, refresh
    tokens, `rest/v1` upserts with every column (`on_conflict=id`, `merge-duplicates`), `seq` cursors per table (500 a
    page), push before pull, folders before notes. Fields are `mne2e:v1:` + base64(nonce | ciphertext | tag); the
    vault key is wrapped under PBKDF2-SHA256(passphrase, salt, 310 000). PBKDF2 is written out over HMAC-SHA256 so the
    passphrase is UTF-8 on every Android provider. Local rules copy `NoteStore.applyRemote`: the newer `updated_at`
    wins, deletes stick, a different account gets everything pushed and pulls from the start.
  - Also handles the sign-in **link** (`memorynotes://auth-callback`), in case the email has no code.
  - Storage: one JSON file in app-private storage (`notes.json`, written then renamed), not Room: fewer moving parts
    for a few hundred notes. Note text is in the clear there, like the Mac's SQLite; backup is off. The session and
    vault key are in a small file sealed by an AES key that never leaves the Android Keystore. Rejected:
    EncryptedSharedPreferences (androidx.security-crypto is deprecated).
  - Versions (they were already in the Gradle cache): Gradle 9.8.1 wrapper, AGP 9.4.1 with its built-in Kotlin
    2.4.21, Compose BOM 2026.09.00 (needs compileSdk 37), minSdk 26, targetSdk 36. Dependencies: activity-compose and
    material3, plus junit, org.json and androidx.test runner for tests only.
  - New notes get lowercase uuids (Postgres returns them that way); pulled ids are lowercased.
  - An edit is saved after 0.5 s and pushed 2 s later (like the Mac); leaving the app saves and pushes. Opening a note
    without typing changes nothing, so untouched Markdown goes back byte for byte.
- **Shortcuts:** no snapshots (the Mac calendar's history) and no images are pulled or pushed; an image stays as its
  Markdown text. No realtime and no 60 s timer: it pulls when the app comes to the front and on pull-to-refresh. A
  pull doesn't refresh a note that's open in the editor; typing in it then wins over the other device's edit (newer
  wins). Folders can't be created, renamed or assigned; pins and colours can't be changed. Locked notes can't be deleted
  here. Dates in titles show in the phone's medium date format, not the Mac's date setting. One unreadable synced row
  stops the pull with an error, as on the Mac.
- **Status:** Built, not tried against the real project. 20 JVM tests pass (`./gradlew testDebugUnitTest`):
  vectors made with CryptoKit/CommonCrypto (PBKDF2 key, wrapped vault key, sealed field, sealed image) open in Kotlin,
  and a Swift script opened Kotlin's own sealing; with a byte flipped it refuses it. Store rules (newer wins,
  tombstones, mark-pushed, account switch, row columns) are tested too. On an API 35 emulator: the same vectors and the
  Keystore secrets pass on device (`connectedDebugAndroidTest`), and the app starts on the sign-in screen. Not
  verified: real sign-in, vault, push and pull, and the editor and list screens past sign-in.

## D67 — Each calendar event has its own colour (2026-11-03)

- **Asked by the user:** right-click → Color changed every event in the note (D65's choice, the note's label); only the
  event right-clicked should change.
- **Chosen by the user:** a tag right after the date, `@2026-11-05{red}` (a range's on its first-written date). The
  Mac, iPhone and browser editors hide it and tint the date chip; it shows while the cursor is in the date, like the
  date's source. Android's text box and older versions show it as text. Rejected: a coloured-square emoji (no pink or
  cyan), and keeping it outside the text (needs a new synced column and breaks when lines move).
- **By Claude:** an event's colour is its own, else its note's label, else the picked one (D61). Right-click → Color
  writes or removes the tag on that line (`NotesModel.setColor`); the sidebar's Color still sets the note's label. A
  range keeps one tag: setting it strips any on the other end. Unknown words (`{bogus}`) are ignored.
- **Status:** Done. Swift tests (parse, own colour beats label, rewrite incl. a backwards range), editor test (chip
  tint, hidden tag, round trip). Not tried by hand.
- **Bug (user report):** the colour showed for a moment, then the old one came back. setColor went through update(),
  which saves only pin, colour and folder, so the text change never reached the database and the next reload undid it.
  Now it's saved like typing; a test reads it back from the store (it failed on the old code).
- **Asked by the user (follow-up):** a range's start and end should show the same colour. In the editor both date
  chips of a range take the colour written on either end (the calendar already coloured the whole bar).

## D68 — Swipe the calendar to move it (2026-11-03)

- **Asked by the user:** swipe left or right on the calendar to move it.
- **Mac:** a two-finger sideways swipe on the trackpad over the calendar steps one month, week or day (whichever is
  showing): fingers left = next, right = previous, like Calendar. One step per swipe; the coasting after the fingers
  lift and mouse wheels are ignored; vertical scrolls pass through. SwiftUI has no trackpad swipe on the Mac, so it
  watches scroll events (they are not swallowed).
- **iPhone:** a sideways drag of 60 pt or more does the same; it runs alongside the lists, so they still scroll.
- **Rejected:** NSEvent swipe(with:), which fires only for three-finger swipes when the user has set that up.
- **Not done:** Android has no calendar yet.

## D69 — In a browser, the Mac panel's notes are the page's notes (2026-11-05)

- **Asked by the user:** a note made from the Mac app on a Brave page should show in the extension on that page.
- **Bug:** the Mac panel saved it as an app note on Brave's window title ("com.brave.Browser/Page title"); the
  extension only shows website notes on the page's address, so it never saw it.
- **Chosen by the user:** read the address through Accessibility (already granted), not via the extension (would
  need a new store submission) or AppleScript (a "control Brave" prompt). Brave exposes no page content and no AXURL
  to Accessibility, but its address bar's text is readable: the text field in the window toolbar. It hides
  "https://" and "www."; the query and hash are dropped, giving the same target the extension makes
  (`Note.pageTarget`). Searches, "brave://" pages and the like give no page. While the address bar has focus
  (typing), the place isn't updated.
- **Now:** in Chrome, Brave, Edge, Vivaldi and Chromium the Mac panel shows the open page's website notes (plus any
  window-title notes, as before) and its + makes a website note on the page. Arc keeps window-title notes (no
  address bar in its toolbar).
- **Chosen by Claude:** the Mac panel doesn't open by itself for a page's own notes, since the extension already
  opens its panel in the page; ⌥⇧M still shows them. Window-title notes still open it as before.
- **Chosen by the user:** notes made earlier from the Mac on Brave stay window-title notes (no reliable way to map
  a title to an address).
- **Bug (user report, follow-up):** the Mac panel kept popping up on pages with no notes. Brave's front window had
  an empty title most of the time (73 of 100 samples, 0.2 s apart); an empty title makes the place just "Brave",
  and by "parents see children" every Brave window-title note showed there. Now in a browser a window-title note
  shows only on exactly its title; other apps keep parents seeing children.

## D70 — A YouTube video, or a search, is its own page (2026-11-06)

- **Bug (user report):** every YouTube video showed the same note. Page keys drop the query, and YouTube names the
  video there (watch?v=…), so all videos were the one page "youtube.com/watch".
- **Chosen by the user:** keep only the part of the query that names the page, on a short list of sites: YouTube's
  `v` (watch) and `search_query` (results), Google's `q` (/search, any google.* domain). Everything else is
  unchanged, so existing notes stay where they are. Value encoded like encodeURIComponent: "?v=9GHCiiDLHQ4".
  The same rule lives in `Note.pageTarget` (Mac, iPhone share sheet, MCP, address bar) and extension/content.js.
- **Rejected:** keeping every query minus tracking parameters (notes would get lost on pages whose query keeps
  changing, and existing notes on such pages would stop matching).
- **Chosen by the user:** the existing note on "youtube.com/watch" no longer shows on videos; they move it by hand.
  To make that easy, the Mac's "Edit Address…" field turns a pasted link into this key when editing ends.
- **Needs:** a new extension version in the Chrome Web Store.
- **Bugs found in review (D69 follow-up):** (1) the panel decided whether to open using the previous place, since
  @Published announces a value before storing it; the place is now passed in. (2) Switching to a browser whose
  address bar had focus skipped the update, so the panel kept the last app's place and + saved there; now it updates
  with no page.

## D71 — The website and the download live on Cloudflare (2026-11-19)

- **Asked by the user:** distribute the Mac app from noteanywhere.app instead of only GitHub, at no cost.
- **Domain:** registered at GoDaddy, DNS moved to Cloudflare (nameservers adele/kip.ns.cloudflare.com).
- **Chosen by Claude:** Cloudflare Workers static assets (`wrangler.jsonc`, assets = `site/`), with the DMG served
  from the same site at https://noteanywhere.app/NoteAnywhere.dmg. Static asset requests are free and unmetered, and
  files up to 25 MiB are allowed (the DMG is about 11 MB), so no R2 bucket, card or second domain is needed. The DMG
  is copied into `site/` at deploy time and gitignored, never committed.
- **Rejected:** R2 on dl.noteanywhere.app (R2 must be switched on in the dashboard, which may ask for a card);
  Cloudflare Pages (Wrangler now steers static sites to Workers); GitHub Pages (the DMG would stay on github.com).
- **Page design (user):** Apple-style, very little text, real screenshots; demo content only (test stores, hidden
  browser), never the user's notes. Desktop photos from Wikimedia Commons, credited in the footer.

## D72 — Version in the corner, feedback without leaving the app, a block menu on ⋮⋮ (2026-11-19)

- **Asked by the user:** show the app's version, and a quick way to email a problem or a suggestion from inside the
  app and from the website. Placed by the user in the sidebar's bottom corner (plus Help menu and menu bar items).
- **Chosen:** one endpoint, `POST noteanywhere.app/api/feedback` (`worker/index.js`), used by the Mac app and the
  website's footer form. Static files are still served before the worker runs, so only feedback counts as a worker
  request. It emails timeupvishwa@gmail.com through Cloudflare Email Routing's `send_email` binding (free), from
  feedback@noteanywhere.app, with Reply-To set when the sender gives an address. Guards: 5 messages a minute per IP
  (rate-limit binding), 5,000 characters, kind must be Problem or Suggestion, CR/LF stripped from header values, and
  a hidden field bots fill in. A failed send keeps the text and offers Mail (app) or the address (site).
- **Rejected:** a pre-filled Mail draft (leaves the app, and fails for people without Apple Mail; can't serve the
  website); a third-party form service (another account, and the messages would pass through it).
- **Needs (one-time, dashboard):** Email Routing on for noteanywhere.app, with timeupvishwa@gmail.com verified as a
  destination address.
- **Version:** `scripts/make_app.sh` stamps the `VERSION` file into Info.plist, so local builds show it too;
  release.sh still overrides it with the tag.
- **Asked by the user:** right-click (or Control-click) a block's ⋮⋮ handle to change it: turn into Text, Heading
  1–3, a list, Quote or Code (its own kind is checked and does nothing), Duplicate or Delete. Tables, pictures,
  lines and maths only get Duplicate and Delete. In the shared editor, so the extension gets it too.
- The block menu has a search field on top: typing filters the actions by name or other words ("remove" finds
  Delete), ↑/↓ pick and Return runs.

## D73 — Starred notes, and bringing iPhone and Android up to the Mac (2026-11-19)

- **Asked by the user:** star and pin on every platform. **Pin** keeps its meaning: pinned notes sit in a "Pinned"
  section at the top. **Star** doesn't move a note; a "Starred" filter (Mac sidebar under All Notes, iPhone list
  filter, Android chip) shows only starred notes. Chosen over "star replaces pin" so both stay useful.
- **Data:** `notes.starred` (SQLite schema v6; Supabase migration `20261119120000_starred.sql`), saved with the
  other metadata (updated_at + 1 ms) and synced like pinned. Older apps don't send it; a PostgREST upsert leaves
  columns it doesn't name alone, so their edits keep the star. The migration must be applied before releasing an
  app that selects the column, or that app's pull fails.
- **Parity, phased:** A = star everywhere + Android basics (pin, colour, duplicate, share, sections); B = iPhone
  gaps (tag list, tap a tag, folder rename/delete, creating note links, block menu by touch). C (Android rich
  editor, images) and D (locked notes on phones, Trash, Android calendar/graph) wait for the user's go-ahead.

## D74 — The website moves to a private repo; main changes only through pull requests (2026-11-20)

- **Asked by the user:** the website (`site/`, the feedback `worker/`, `wrangler.jsonc`) and non-public material
  (launch-post drafts) live in the private repo `Vishwas3000/NoteAnywhere_personal`; this repo keeps the apps, the
  extension and the editor. What was already pushed here stays in this repo's history.
- **Asked by the user:** `main` is the production branch in both repos and changes only through a pull request.
  Anyone can contribute to this repo through pull requests; the maintainer reviews and merges, and is the only one who
  publishes releases (the DMG is signed with the maintainer's Developer ID).
- **Chosen by Claude, asked to decide what else moves:** the `launch/` kit (posts and the Web Store listing) and
  `docs/RELEASING.md` (the maintainer's release runbook, with account steps) moved to the private repo too. Staying
  here: `PRIVACY.md` (the Chrome Web Store links to it), `docs/DECISIONS.md` and `docs/ROADMAP.md` (contributors need
  them), `supabase/` (the sync schema the apps use) and `docs/images/` (the README's pictures). Website decisions
  from now on are recorded in the private repo.
- **Asked by the user (DMG):** releases are built, signed, notarized and published only from the maintainer's Mac;
  the Developer ID certificate never goes to GitHub. The tag-triggered GitHub release workflow (which never had its
  secrets and failed on every tag) is deleted. Rejected: building on GitHub Actions with the certificate as a secret
  behind an approval step. Publishing (GitHub Release, website, update feed) is a script in the private repo.
- **Asked by the user (updates):** Sparkle, so installed copies update themselves. Its EdDSA signing key lives only
  in the maintainer's keychain, like the certificate.

## D75 — Sparkle updates in the Mac app (2026-11-20, subagent)

- **Asked by the user (D74):** Sparkle, so installed copies update themselves. The app side is here; publishing
  (GitHub Release, website, appcast) is a script in the private repo.
- **Feed and archives**, fixed because that script relies on them: the feed is `https://noteanywhere.app/appcast.xml`
  (`SUFeedURL`); each update is the notarized DMG on GitHub Releases,
  `https://github.com/Vishwas3000/NoteAnywhere/releases/download/vX.Y.Z/NoteAnywhere-X.Y.Z.dmg`, signed with
  Sparkle's `sign_update`. Sparkle compares `CFBundleVersion`; release.sh sets it and `CFBundleShortVersionString` to
  X.Y.Z, and the appcast uses X.Y.Z for both.
- **Key:** the EdDSA private key exists only in the maintainer's keychain (Sparkle's `generate_keys`); Info.plist has
  only the public key (`SUPublicEDKey`). The maintainer generated it on 2026-11-20. The private key must be backed up
  (`generate_keys -x`): installed copies accept only updates it signs, so losing it ends their updates. release.sh
  refuses to build with a placeholder. The tools are in `.build/artifacts/sparkle/Sparkle/bin/` once the package
  resolves.
- **Chosen by Claude:** Sparkle 2.10.1 through SwiftPM, pinned exactly (the newest stable 2.x that was two weeks old).
  `make_app.sh` embeds Sparkle.framework in Contents/Frameworks (the binary's rpath `@executable_path/../Frameworks`
  comes from Package.swift) and removes its XPC services, which only sandboxed apps use; Sparkle's docs allow removing
  them, and it leaves no Downloader.xpc entitlements to keep. install.sh and release.sh sign Autoupdate, Updater.app,
  the framework and then the app, Sparkle's documented order, never `--deep`. Sparkle's defaults stay: it asks on the
  second launch whether to check automatically (daily), and sends no system profile. Check for Updates… is after
  About in the app menu, and in the menu-bar menu.
- **Dev builds don't update:** install.sh removes `SUFeedURL` from its bundle, and the app starts Sparkle only when
  the feed is there, so a dev build never replaces itself with a release; its Check for Updates… is greyed out.
  Rejected: `SUEnableAutomaticChecks` false (a manual check could still install a release over the dev build, and
  Sparkle refuses to start with the placeholder key, with an alert at every launch).
- **Status:** Proposed. Checked: `swift test`; an ad hoc build loads the embedded framework; release.sh with a
  throwaway test key builds a Developer ID app that passes `codesign --verify --deep --strict` ("Unnotarized
  Developer ID" until notarized); a `sign_update` signature of its DMG verifies with CryptoKit; Sparkle starts with
  that Info.plist and refuses the placeholder key (checked outside the app). The real public key is in Info.plist
  (2026-11-20). Not yet: notarization, the menu items on screen, and an update installed from a real feed.

## D76 — Note and folder ids are lowercase; synced duplicates are merged (2026-11-20)
- **Bug (user reported: "after sync there are duplicates for all the notes"):** the Mac and iPhone made uppercase
  UUIDs. The sync server's uuid columns return them lowercase, and the pull matched ids exactly, so every note a device
  pushed came back as a second note (29 of 33 notes and their snapshots on the maintainer's Mac). Deleting one copy
  would have deleted both: they are one row on the server. Images (lowercase since D53) and Android (lowercase ids)
  were not affected. Released 0.1.2 has the bug.
- **Fix:** new note and folder ids are lowercase. Schema v7 merges each uppercase/lowercase pair, keeping the newer
  edit. It first moves snapshots, tags, embeddings, suggestions, links and attachments to the lowercase id, so ON
  DELETE CASCADE removes nothing when the extra copy goes. Then it lowercases the remaining ids, folders included;
  foreign keys are checked at COMMIT. Ids that arrive from outside are lowercased too: browser panels opened before
  the update, MCP, `note://` links in existing text and restored note windows.
- **Rejected:** a text id column on the server (the uuid type already lowercased the existing rows, so the Mac's
  uppercase copies would still not match); lowercasing in every query (many call sites, easy to miss one).
- **Checked:**
  - a test that gets 2 notes with uppercase ids and 1 with the fix;
  - a migration test: both directions of "newer", a snapshot day on only one copy, a tag on both, a folder pair;
  - the migration SQL on a copy of the maintainer's database: 62 rows became 33 and none went missing. The 2 notes
    edited after the sync kept their newest text, and no note changed between deleted and not deleted.
- **Status:** Done.
