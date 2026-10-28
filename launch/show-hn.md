# Show HN

**Submit:** URL = https://github.com/Vishwas3000/NoteAnywhere (the repo, not a landing page: people can read the
code and download the DMG from there). Then post the first comment below right away.

**Title** (HN allows 80 characters):

> Show HN: NoteAnywhere – Mac notes tied to the app, chat or web page you're in

Alternatives:

> Show HN: A local-first Mac notes app that knows which Slack DM you're in
>
> Show HN: NoteAnywhere – context-aware notes for macOS, with on-device search

**Rules** (https://news.ycombinator.com/showhn.html): it must be something people can try now, without a signup
(true: the DMG needs no account). Don't ask anyone to upvote or comment, and don't post from more than one account.
Be around to answer questions for the first few hours. HN readers will ask about the AI-assisted build, privacy and
the Accessibility permission; answer plainly.

---

## First comment

NoteAnywhere is a macOS notes app (plus a Chrome/Brave extension) that attaches each note to the place you wrote it:
an app and window, like a Slack DM or a VS Code project, or a web page. When you come back to that place, a small
floating panel shows the note. Around that it's a normal notes app: Markdown editor, search, #tags, a calendar, a graph.

How it works:

- Context comes from the front window's title, read through the Accessibility API on focus/title-change
  notifications. "Sam (DM) - Acme - 8 new items - Slack" becomes Slack › Acme › Sam (DM): split on " - ", "—", "|",
  use the app's own name to find the broad end, drop unread counts. No per-app parsers, except a one-entry table for
  WhatsApp, whose title is just "WhatsApp"; there it reads the chat header element and skips the message list.
- A place sees the notes of the places under it, for apps and pages alike. Website notes are a range query on
  `host/path` in SQLite.
- The extension talks to the app through Chrome native messaging. The host is the app's own binary: `main` checks
  whether argv[1] starts with `chrome-extension://`. So the extension works when the app is closed.
- The browser panel is an extension iframe. My first version injected it into the page, and some sites stole its
  keystrokes.
- Storage is SQLite in WAL mode shared by the app and the short-lived host process; `notify_post` tells every
  process to reload, and the extension keeps one host connection open to stream "changed" events.
- Search is all-MiniLM-L6-v2 running locally (swift-embeddings) plus a keyword score. On a small test of 8 notes ×
  7 paraphrased queries, Apple's NLEmbedding found the right note 2 times, MiniLM 6.
- Rewrites (grammar, shorter, checklist) use Apple's on-device Foundation Models on macOS 26.
- Optional sync through Supabase: a Postgres trigger keeps the newer `updated_at`, deletes stay deleted, and each
  write gets a sequence number devices pull after.

Idle CPU is about 0%, memory 37–65 MB. Notes stay in SQLite on your Mac; nothing leaves it unless you turn on sync.

Limits: titles carry names, not ids, so renaming a channel starts a new place. Chrome and Brave only. macOS 15+.

I built it quickly with a lot of help from Claude Code. I made the product calls; the repo has a decision log
(docs/DECISIONS.md) that records each decision, its reason, what was rejected and who made it.

GPL-3.0. DMG: https://github.com/Vishwas3000/NoteAnywhere/releases/latest. Extension: {{CHROME_WEB_STORE_URL}}

I'd especially like to hear which apps give useless window titles, and whether the auto-opening panel is helpful
or annoying.
