# NoteAnywhere Privacy Policy

Last updated: 2026-11-20

This policy is also published at https://noteanywhere.app/privacy.

NoteAnywhere is a notes app for macOS with a companion extension for Chrome and Brave. It is open source
(GPL-3.0), so every claim below can be checked in the code at https://github.com/Vishwas3000/NoteAnywhere.

The short version: your notes live in a database on your Mac. The AI features run on your Mac. Sync is off unless
you turn it on. There are no analytics, no ads, no tracking and no account unless you choose to sync.

## What is stored, and where

**On your Mac.** Everything NoteAnywhere keeps is in one SQLite database at
`~/Library/Application Support/MemoryNotes/memorynotes.sqlite` (the folder still uses the app's former name). It holds:

- your notes (Markdown text), with the app, chat or web page each one belongs to, when it was created and edited,
  and its folder, pin, star and color label;
- your folders' names;
- one snapshot per note for each day you edited it, which the calendar shows;
- search vectors computed from your notes (see "On-device search");
- icons of the websites you have notes for.

The same folder holds images you paste into notes (`images/`) and the search model once it is downloaded (`models/`). A few settings (such as whether sync is on,
where the floating panel sits and whether to check for updates) are kept in the app's standard macOS preferences. Your macOS Keychain, never the
database, holds the sync sign-in session and your sync encryption key if you sync, and the password for locked notes
if you lock any, so Touch ID can unlock them. A locked note's text is stored encrypted with that password (AES-GCM).

**In your browser.** The extension stores no notes. It keeps three settings in Chrome's extension storage: whether you
widened the panel, where you moved it and how big you made it. Notes you write in the browser are handed to the NoteAnywhere app on your Mac, which saves them in
the database above.

**Deleting a note** hides it everywhere in the app and the extension. Its row stays in the database marked as
deleted, so that the deletion can reach your other devices if you sync. Deleting the `MemoryNotes` folder removes
everything.

## What the app reads to know where you are

NoteAnywhere shows notes for the app, chat or project in front of you. To do that it asks for the macOS
**Accessibility** permission and uses it for exactly three things:

1. **The title of the front window** of the app you're using (for example "Q4 plan - Acme - Slack"), read when the
   front window or its title changes.
2. **For WhatsApp only**, whose window title is just "WhatsApp": the name shown on the open chat's header, checked
   once a second while WhatsApp is in front. The search for that header skips the message list.
3. **In Chrome, Chromium, Brave, Edge and Vivaldi only:** the address in the browser's address bar, so the Mac panel
   can show that page's notes. It is turned into the page's domain and path (and, on a YouTube video or a YouTube or
   Google search, the video id or the search words), as the browser extension does. It is not read while you type in
   the address bar.

It never reads message contents, what you type, or what's on your screen, and it does not use Screen Recording.
Window titles and addresses are used in memory to pick which notes to show. They become part of your data only when
you create a note there: the note then remembers its place, for example "Slack › Acme › #design-review".

Without the permission, NoteAnywhere still works, with notes per app instead of per window.

## What the browser extension reads

On each page you open, the extension sends the page's address to the NoteAnywhere app on your Mac through Chrome's
native messaging, so the app can tell whether you have notes for that page. The address is the domain and path,
without the query string or `#` fragment, except where the part after "?" names the page: on a YouTube video it
includes the video's id, and on a YouTube or Google search, the search words. The extension also reads the page's title, to show it in the panel and to save it with a note you create there. It
does not read the page's contents, does not track your browsing, and sends nothing to any server. The address lookup happens on your
Mac and is not stored.

To show the page's icon in its panel, the extension loads `/favicon.ico` from the site you are already on.

## Network connections

NoteAnywhere connects to the internet only for these reasons:

| What | When | Who receives the request | What is sent |
|------|------|--------------------------|--------------|
| Website icons | The first time a site you have notes for needs its icon | That website itself | A normal request for its home page and icon. No third-party favicon service is used, so no one else learns which sites you keep notes on. |
| Search model | Your first search, once (about 87 MB) | Hugging Face (huggingface.co) | A download request for the public model `sentence-transformers/all-MiniLM-L6-v2`. No notes or queries are sent. |
| Link previews | Only when you paste a link into a note and choose Mention or Card | That website itself | A normal request for the page, and for its preview picture and icon, which are kept as images in the note |
| Feedback | Only when you press Send in Send Feedback (in the app, or the form on noteanywhere.app) | noteanywhere.app, which emails it to the developer | Your message, the email address you give for a reply (optional), and the NoteAnywhere and macOS versions. Your IP address is used only to allow 5 messages a minute and is not stored. |
| Web pictures in notes | When a note that shows a picture by its web address (for example from pasted Markdown) is on screen, in the app or the browser panel. Pasted and dropped pictures are kept in the note instead. | That website | A normal request for the picture, as a web page would make |
| Sync | Only if you turn sync on and sign in | Supabase (see below) | Your notes and your email address |
| Updates | Once a day if you allow automatic checks (the app asks on its second launch), and when you choose Check for Updates… | noteanywhere.app for the update feed (`https://noteanywhere.app/appcast.xml`); GitHub (Releases) for downloading an update | A request for the feed, with NoteAnywhere's version in the user agent, and a normal download of the new version. No notes, no personal data and no system profile. |

There are no analytics, no telemetry, no crash reporting and no advertising.

## On-device AI

**Search.** Semantic search uses the all-MiniLM-L6-v2 model, running on your Mac. Your notes and search queries are
turned into vectors locally and never leave your Mac.

**✨ actions** (fix grammar, make clearer, make shorter, turn into a checklist, add a title) use Apple's on-device
Foundation Models (Apple Intelligence, macOS 26 or later). The text is processed on your Mac. When you use these
actions from the browser panel, the text goes to the NoteAnywhere app on your Mac, not to a server.

**Writing Tools.** NoteAnywhere's editor allows macOS Writing Tools, a system feature that Apple provides and
controls. When you use it, Apple's privacy terms for Apple Intelligence apply.

## AI assistants you connect

NoteAnywhere can act as an MCP server for AI assistants such as Claude, Codex or Gemini, but only if you add it to
that assistant yourself. The server runs on your Mac. It can search and read your notes (not locked ones), list
tasks, and create or change notes; it can't delete notes. What it returns goes to the assistant you connected, and
that assistant's own privacy terms cover what it sends to its servers. NoteAnywhere itself sends nothing anywhere.

## Optional sync

Sync is off by default. If you turn it on in Settings, you sign in with your email address: you receive a one-time
sign-in link or code, and there is no password.

With sync on, your notes are copied to a database hosted on [Supabase](https://supabase.com) and operated by the
NoteAnywhere developer. They are **end-to-end encrypted**: before anything leaves your Mac, a random 256-bit key for
your account seals (AES-GCM) each note's text, the app, chat or page it belongs to and that place's name (such as a
page title), your folders' names, the daily snapshots the calendar uses, and the images in your notes. The server keeps
that key only locked with your sync passphrase, which never leaves your devices, so neither the developer nor Supabase
can read what is sealed. If you forget the passphrase, the cloud copy can't be opened; the notes on your Mac are
unaffected.

What the server can see:

- your email address and account id (managed by Supabase Auth, which also keeps sign-in records such as times and
  IP addresses, and sends the sign-in emails);
- each note's id, whether it is an app or website note, its timestamps, whether it was deleted or locked, and its
  folder, pin, star and color label;
- each image's id, creation time and file type (such as PNG).

Search vectors and website icons are not synced. Data travels over HTTPS, and database rules ensure each account can
only read and write its own data.

Signing out stops syncing and leaves your notes on your Mac. To delete your synced data and account, email
timeupvishwa@gmail.com from the address you signed in with; deleting the account deletes all of its notes and snapshots
from the cloud database.

## Sharing and selling

NoteAnywhere does not sell, rent or share your data, and does not use it for advertising, profiling or
creditworthiness. Your notes are used only to provide NoteAnywhere's features to you.

The use of information received from the browser extension complies with the
[Chrome Web Store User Data Policy](https://developer.chrome.com/docs/webstore/program-policies/), including its
Limited Use requirements.

## Children

NoteAnywhere is not directed at children under 13 and does not knowingly collect their data.

## Changes

Changes to this policy are published at https://noteanywhere.app/privacy and in this file, with a new date at the
top. Its history is in the repository's git log.

## Contact

Questions or requests: timeupvishwa@gmail.com, or open an issue at
https://github.com/Vishwas3000/NoteAnywhere/issues.
