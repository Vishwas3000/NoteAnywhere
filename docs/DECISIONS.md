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
- Results expand into an editor in place (popup and overlay) instead of opening the main window.
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
