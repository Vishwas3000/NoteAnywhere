# Product Hunt

**Name:** NoteAnywhere

**Tagline** (60 characters max, this one is 55):

> Mac notes that show up in the app or page they're about

Alternatives: "Notes that know which Slack DM or web page you're in" (52) · "Local-first Mac notes that follow your windows" (46)

**Links:** https://github.com/Vishwas3000/NoteAnywhere (main) · DMG
https://github.com/Vishwas3000/NoteAnywhere/releases/latest · {{CHROME_WEB_STORE_URL}}

**Pricing:** Free. **Open source:** yes (GPL-3.0).

**Topics:** Mac · Productivity · Note and Writing Apps · Open Source · Chrome Extensions

**Thumbnail:** 240×240, the app icon or a short loop of the panel appearing (see assets.md, PH-0).

---

## Description (260 characters max)

> Write a note in a Slack DM, a VS Code project or on a web page, and it shows up there next time. NoteAnywhere is a
> free, open-source Mac notes app with a Chrome extension, on-device semantic search and Apple Intelligence. Notes
> stay on your Mac.

(245 characters.)

---

## Maker comment

Hi Product Hunt, I'm the maker of NoteAnywhere.

The idea is simple: a note should live where it's about. Write one while you're in a Slack DM, a VS Code project, a
WhatsApp chat or on a GitHub page, and next time you're back there, it's waiting in a small floating panel.

How it knows where you are: it reads the front window's title (with your permission) and turns
"Sam (DM) - Acme - Slack" into Slack › Acme › Sam (DM). For web pages, a Chrome/Brave extension shows a page's notes
right on the page, synced live with the Mac app.

Around that is a full notes app:

- ⌥⇧Space to search everything by meaning, with a model that runs on your Mac
- ✨ Apple Intelligence actions: fix grammar, make shorter, turn into a checklist (macOS 26)
- #tags, a knowledge graph, and a calendar where `@fri` puts a task on Friday
- a Markdown editor with Notion-style drag handles, in an Apple Notes–style window

It's local-first: your notes are in a SQLite database on your Mac, the AI runs on-device, and sync is off unless you
turn it on. No account needed, no analytics.

It's free and open source under GPL-3.0. An iPhone app and iCloud sync are next.

I'd love to hear where the auto-opening panel helps and where it gets in the way, and which apps it should
understand better.

---

## Gallery (1270×760, in this order)

Shot ids refer to [assets.md](assets.md).

1. **PH-1 Hero.** Slack DM with the floating panel showing its notes. Caption: "Notes come back when you return to
   the DM, channel or project."
2. **PH-2 Browser.** A GitHub repo page with the extension panel. Caption: "Notes on any web page, live-synced with
   the Mac app."
3. **PH-3 Search.** The ⌥⇧Space popup finding a note by meaning. Caption: "Search by meaning, on your Mac."
4. **PH-4 Main window.** Apple Notes–style sidebar, a note with a checklist, #tags and date chips. Caption: "A full
   Markdown notes app."
5. **PH-5 Calendar.** Week view with Planned tasks. Caption: "Type @fri and it's on Friday."
6. **PH-6 Graph.** Notes, app hubs and tag hubs. Caption: "See how your notes connect."
7. **PH-7 Privacy.** A plain card: "Local SQLite · On-device AI · Sync off by default · GPL-3.0".

Optional video: the 30-second hero GIF as an MP4 (assets.md, V-1).

**Launch timing:** Product Hunt days start at 12:01 am Pacific. Tuesday to Thursday get the most traffic and the most
competition; a weekend launch is quieter but easier to place. Ask people you know to look at it, but don't ask for
upvotes: Product Hunt penalises vote rings.
