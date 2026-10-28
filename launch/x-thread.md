# X thread

Seven posts, each under 280 characters (approximate counts in brackets; X counts each link as 23). Lines aren't
wrapped, so each post pastes as is. Attach the media named under each.

---

**1/7** [234]

I built NoteAnywhere: a free, open-source Mac notes app where notes stay with the place they're about.

Write a note in a Slack DM, a VS Code project or on a web page. Next time you're there, it's waiting in a small floating panel.

🧵

*Media: hero GIF (assets.md, V-1)*

---

**2/7** [232]

How it knows where you are: it reads the front window's title through macOS Accessibility.

"Sam (DM) - Acme - 8 new items - Slack" → Slack › Acme › Sam (DM)

A few generic rules, no per-app parsers. It never reads message contents.

---

**3/7** [208]

Web pages get notes too. A Chrome/Brave extension shows a page's notes on the page, and edits sync live with the Mac app.

A page also sees its sub-pages' notes: github.com lists what you wrote on every repo.

*Media: browser panel (S-2)*

---

**4/7** [214]

⌥⇧Space searches everything by meaning, from anywhere.

It runs all-MiniLM-L6-v2 on your Mac plus exact-word matching. In a small test, it found the right note 6 times out of 7; Apple's built-in embeddings found 2.

*Media: search GIF (V-2)*

---

**5/7** [240]

It's a full notes app, too:

✨ Apple Intelligence: fix grammar, shorten, make a checklist (on-device)
#tags and an Obsidian-style graph
type @ for a date menu; tasks land on the calendar
Notion-style drag handles
an Apple Notes–style window

*Media: graph (S-6) or calendar (S-5)*

---

**6/7** [170]

Local-first: notes live in SQLite on your Mac, AI runs on-device, sync (Supabase) is off unless you turn it on. No account, no analytics.

Idle CPU ≈ 0%, memory 37–65 MB.

---

**7/7** [202]

Free, GPL-3.0, macOS 15+. Built fast with a lot of help from Claude Code; every decision is logged in the repo.

Mac app: https://github.com/Vishwas3000/NoteAnywhere/releases/latest
Extension: {{CHROME_WEB_STORE_URL}}

Tell me what breaks.
