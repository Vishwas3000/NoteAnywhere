# Roadmap

Each phase lands as its own commit(s). Decisions behind it are in [DECISIONS.md](DECISIONS.md).

| Phase | Scope | Status |
|-------|-------|--------|
| 0 | Mac app, per-app overlay, Chrome/Brave extension, Native Messaging bridge | Done |
| 1a | Calendar: daily snapshots; Month / Week / Day views; filter by app/site | Done |
| 1b | Semantic search (all-MiniLM-L6-v2 + keyword): main window, ⌥⇧Space popup, Mac overlay, browser overlay | Done |
| 2 | Shared TipTap editor (Markdown) in the Mac app (WebView) and the browser overlay: full Markdown (headings, bold/italic/strike, code, quotes, lists, task lists, tables, links, images, rules); lists continue on Enter, Tab/Shift-Tab indent, numbering stays in order (same in app and browser); links between notes, and an Info panel listing every formatting shortcut | Done, except a picker for inserting links to other notes (note:// links already open) |
| 3 | Organize: folders, pinned notes, #tags | Done: #tags, folders, pins, color labels, Apple Notes–style right-click menu (all synced). In progress: locked notes |
| 4 | Media: images & files, Notion-style web link previews, sketches, audio + on-device transcript, scan from iPhone | Images done (paste/drop, synced encrypted, D53); the rest planned |
| 5 | Quick Note hotkey, export (Markdown/PDF) & share sheet | Planned |
| 6 | iPhone app + sync | Supabase sync done; iPhone app (Share + Safari extensions) in progress; iCloud sync planned |
| — | SQLite storage; parent pages show child-page notes; single "+ New note"; UI review fixes | Done |
| — | Window context (channel/DM, project/file), Apple Intelligence, knowledge graph, plain notes, dates and tasks, block drag handle | Done |
