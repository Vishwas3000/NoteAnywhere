# Reddit

One main post for r/macapps, then short variants, each with its own angle. Post them on different days, not all at
once: Reddit's spam filter flags the same link landing in several subreddits within minutes, and moderators notice.

Before each post, read the subreddit's sidebar and pinned posts. Rules change, and the notes below are what to check,
not a substitute for reading them.

---

## r/macapps

**Rules to check:** r/macapps allows developers to post their own apps, but expects you to say you're the developer,
to use the right flair, and to state the price. Check whether there's a current rule about AI-assisted apps; if
there is, add the disclosure line at the bottom of the post. Don't ask for upvotes. Stay and reply to comments for
the first few hours.

**Flair:** the developer / free / open-source flair the sidebar lists.

**Title:**

> NoteAnywhere: a free, open-source notes app that shows your notes in the app, chat or web page they're about

**Body:**

Hi r/macapps, I'm the developer.

A note about a Slack DM belongs in that DM, not in a folder you'll forget to open. NoteAnywhere ties each note to
where you wrote it, and shows it again when you're back there.

- **Notes follow the window you're in.** Write a note in a Slack DM, a VS Code project or a WhatsApp chat, and a
  small floating panel shows it next time you open that DM, project or chat. ⌥⇧M shows or hides it anywhere.
- **Notes on web pages.** A Chrome/Brave extension shows a page's notes in a panel on the page, synced live with the
  Mac app. A page also sees its sub-pages' notes.
- **Find things by meaning.** ⌥⇧Space searches all notes from anywhere, with an on-device model (MiniLM) plus exact
  words.
- **The rest of a notes app:** an Apple Notes–style window with folders, pins and a right-click menu, a Markdown
  editor, #tags, a calendar with dated tasks
  (type `@` for a date menu), an Obsidian-style graph, and Apple Intelligence actions (fix grammar, shorten, turn
  into a checklist) on macOS 26.

![NoteAnywhere showing notes for a Slack DM in its floating panel]({{HERO_GIF_URL}})

**Privacy.** Notes live in a SQLite database on your Mac. Search and the AI actions run on-device. Sync (Supabase,
sign in by email link) is off unless you turn it on. No analytics.

It asks for Accessibility permission, which it uses to read the front window's title (that's how it knows "Slack ›
Acme › #design-review"), and for WhatsApp only, the chat name in the header. It never reads message contents. Without
the permission, notes are per app instead of per window. The full privacy policy is in the repo.

**Free, GPL-3.0.** macOS 15+, Chrome or Brave for website notes.

- Download (notarized DMG): https://github.com/Vishwas3000/NoteAnywhere/releases/latest
- Chrome extension: {{CHROME_WEB_STORE_URL}}
- Source: https://github.com/Vishwas3000/NoteAnywhere

Known rough edges: renaming a Slack channel starts a new place for notes (window titles carry names, not ids), and
it's Chrome/Brave only for now. An iPhone app and iCloud sync are in progress.

I'd really like feedback on two things: does the panel opening by itself feel helpful or intrusive, and which apps
give it a useless window title? Those are the cases I can fix fastest.

*Optional disclosure line, if the sidebar asks for one:* I built this with a lot of help from Claude Code; every
design decision and who made it is logged in `docs/DECISIONS.md` in the repo.

---

## r/opensource

**Rules to check:** r/opensource accepts announcements of open-source projects (an OSI license is the bar; GPL-3.0
qualifies), but prefers posts that are about the project as open source, not an ad. Lead with the license and the
code, and link the repo first.

**Title:**

> NoteAnywhere: GPL-3.0 macOS notes app + Chrome extension, local-first with on-device search and AI

**Body:**

I'm the developer. NoteAnywhere is a notes app for macOS whose notes are tied to the app, chat or web page you wrote
them in, and show up again when you're back there.

Repo: https://github.com/Vishwas3000/NoteAnywhere (GPL-3.0)

Things that might interest people here:

- Local-first: one SQLite database on your Mac. Sync is optional and the server schema (Supabase, row-level security,
  last-writer-wins trigger) is in the repo.
- No cloud AI: semantic search runs all-MiniLM-L6-v2 locally; the rewrite actions use Apple's on-device model.
- Every decision is logged with its reason and what was rejected in `docs/DECISIONS.md`.
- Dependencies are MIT/Apache-2.0 (TipTap, swift-embeddings); credits are in the README.

Contributions welcome, especially other browsers (Firefox, Arc) and apps whose window titles don't name the place.
DMG: https://github.com/Vishwas3000/NoteAnywhere/releases/latest

---

## r/SideProject

**Rules to check:** self-promotion is the point of r/SideProject, but low-effort link drops get ignored or removed.
Tell the story and what you learned.

**Title:**

> I built a notes app that knows which Slack DM you're in

**Body:**

I'm the developer. Notes apps don't know where you are: a note about a teammate lives in a folder, not in your DM
with them. So I built NoteAnywhere, a macOS app that ties notes to the app and window you're in (Slack channel or DM, VS Code
project, WhatsApp chat) and to web pages, through a Chrome/Brave extension. Come back to the place and the note is
there in a small floating panel.

What I learned building it:

- Window titles are surprisingly good context. "Sam (DM) - Acme - 8 new items - Slack" cleans up to
  Slack › Acme › Sam (DM) with a few generic rules and no per-app parsers.
- A browser panel injected into the page loses keystrokes to some sites. Moving it into an extension iframe fixed it.
- Apple's built-in sentence embeddings found the right note 2 times out of 7 in my small test; MiniLM found 6 of 7.

It's free and open source (GPL-3.0), runs locally, and AI features are on-device. I built it fast with heavy help
from Claude Code, and kept a decision log of every choice.

![NoteAnywhere demo]({{HERO_GIF_URL}})

DMG: https://github.com/Vishwas3000/NoteAnywhere/releases/latest ·
Extension: {{CHROME_WEB_STORE_URL}} · Code: https://github.com/Vishwas3000/NoteAnywhere

Feedback welcome, especially on whether the auto-opening panel is helpful or annoying.

---

## r/swift

**Rules to check:** r/swift is for Swift discussion, not app ads. Some programming subreddits keep self-promotion
in a pinned weekly thread; if r/swift has one, post there. Otherwise make the post about the code and link the dev.to
write-up rather than the download.

**Title:**

> One Swift binary as both the Mac app and a Chrome native messaging host (plus AXObserver window tracking, MiniLM in Swift)

**Body:**

I'm the developer of NoteAnywhere, an open-source (GPL-3.0) SwiftUI notes app, and wrote up a few parts that might
be useful to others:

- **Same executable, two roles.** Chrome starts the native messaging host with the extension origin as the first
  argument, so `main` checks for `chrome-extension://` and runs a length-prefixed JSON loop over stdin/stdout instead
  of the app. The extension works even when the app is closed.
- **Window context through Accessibility.** An `AXObserver` on the front app for focused-window and title-change
  notifications (no polling), then a generic title parser covered by swift-testing.
- **MiniLM in Swift** via swift-embeddings (MLTensor, macOS 15+), plus a keyword score, vectors stored as Float32
  BLOBs in SQLite.
- **Cross-process live updates** with SQLite WAL and Darwin `notify_post`.
- **Foundation Models** for on-device rewrites, behind `#if canImport(FoundationModels)` and `#available(macOS 26, *)`.
- SwiftPM only, no Xcode project; the app bundle is assembled by a shell script.

Write-up: {{DEVTO_URL}}
Code: https://github.com/Vishwas3000/NoteAnywhere

Happy to answer questions, and to hear where I did something the hard way.

---

## r/ObsidianMD

**Rules to check carefully:** r/ObsidianMD is about Obsidian. Posts about other apps are often removed unless they
work with Obsidian or go in a designated showcase / self-promotion thread. Read the rules first; if in doubt, post in
the pinned thread or message the moderators before posting. Never pitch it as an Obsidian replacement.

**Title:**

> Borrowed Obsidian's #tag and graph semantics for a context-aware Mac notes app (open source)

**Body:**

I'm the developer of NoteAnywhere, a free, open-source macOS notes app. It's not a vault tool and doesn't replace
Obsidian; its notes are tied to the app, chat or web page you wrote them in. But I copied a few things from Obsidian
because they're the best version I know, and I'd like this community's opinion on them:

- **#tags** work like Obsidian's: `#tag` anywhere in the text, nested `#area/topic`, searching `#area` also finds
  `#area/topic`; `# Heading` isn't a tag and nothing inside code counts.
- **The graph**: each note is a node; tags become hubs, nested tags hang off their parent, and you can drag nodes
  and the rest follow. It adds two kinds of edges Obsidian doesn't have: the app or site a note belongs to, and
  "similar meaning" from an on-device embedding model.
- **Dates** use `@2026-10-30` in the text, and it also reads Obsidian Tasks' `📅 2026-10-30`.

Notes are stored as Markdown in SQLite, not as files, so it can't open a vault today. Would a Markdown-folder export
or sync be useful to you?

![NoteAnywhere graph with tag hubs]({{GRAPH_URL}})

Code: https://github.com/Vishwas3000/NoteAnywhere
