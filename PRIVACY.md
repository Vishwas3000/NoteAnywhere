# NoteAnywhere Privacy Policy

Last updated: 2026-10-29

NoteAnywhere is a notes app for macOS with a companion extension for Chrome and Brave. It is open source
(GPL-3.0), so every claim below can be checked in the code at https://github.com/Vishwas3000/NoteAnywhere.

The short version: your notes live in a database on your Mac. The AI features run on your Mac. Sync is off unless
you turn it on. There are no analytics, no ads, no tracking and no account unless you choose to sync.

## What is stored, and where

**On your Mac.** Everything NoteAnywhere keeps is in one SQLite database at
`~/Library/Application Support/MemoryNotes/memorynotes.sqlite` (the folder still uses the app's former name). It holds:

- your notes (Markdown text), with the app, chat or web page each one belongs to, when it was created and edited,
  and its folder, pin and color label;
- your folders' names;
- one snapshot per note for each day you edited it, which the calendar shows;
- search vectors computed from your notes (see "On-device search");
- icons of the websites you have notes for.

The same folder holds images you paste into notes (`images/`) and the search model once it is downloaded (`models/`). A few settings (such as whether sync is on
and where the floating panel sits) are kept in the app's standard macOS preferences. If you sign in to sync, the
sign-in session is kept in your macOS Keychain, never in the database.

**In your browser.** The extension stores no notes. It keeps one setting in Chrome's extension storage: whether you
widened the panel. Notes you write in the browser are handed to the NoteAnywhere app on your Mac, which saves them in
the database above.

**Deleting a note** hides it everywhere in the app and the extension. Its row stays in the database marked as
deleted, so that the deletion can reach your other devices if you sync. Deleting the `MemoryNotes` folder removes
everything.

## What the app reads to know where you are

NoteAnywhere shows notes for the app, chat or project in front of you. To do that it asks for the macOS
**Accessibility** permission and uses it for exactly two things:

1. **The title of the front window** of the app you're using (for example "Q4 plan - Acme - Slack"), read when the
   front window or its title changes.
2. **For WhatsApp only**, whose window title is just "WhatsApp": the name shown on the open chat's header, checked
   once a second while WhatsApp is in front. The search for that header skips the message list.

It never reads message contents, what you type, or what's on your screen, and it does not use Screen Recording.
Window titles are used in memory to pick which notes to show. A title becomes part of your data only when you create
a note there: the note then remembers its place, for example "Slack › Acme › #design-review".

Without the permission, NoteAnywhere still works, with notes per app instead of per window.

## What the browser extension reads

On each page you open, the extension sends the page's address (domain and path, without the query string or `#`
fragment) to the NoteAnywhere app on your Mac through Chrome's native messaging, so the app can tell whether you
have notes for that page. When you create a note on a page, the page's title is saved with it. The extension does not
read page contents, does not track your browsing, and sends nothing to any server. The address lookup happens on your
Mac and is not stored.

To show the page's icon in its panel, the extension loads `/favicon.ico` from the site you are already on.

## Network connections

NoteAnywhere connects to the internet only for these reasons:

| What | When | Who receives the request | What is sent |
|------|------|--------------------------|--------------|
| Website icons | The first time a site you have notes for needs its icon | That website itself | A normal request for its home page and icon. No third-party favicon service is used, so no one else learns which sites you keep notes on. |
| Search model | Your first search, once (about 87 MB) | Hugging Face (huggingface.co) | A download request for the public model `sentence-transformers/all-MiniLM-L6-v2`. No notes or queries are sent. |
| Sync | Only if you turn sync on and sign in | Supabase (see below) | Your notes and your email address |

There are no analytics, no telemetry, no crash reporting, no advertising and no update checks.

## On-device AI

**Search.** Semantic search uses the all-MiniLM-L6-v2 model, running on your Mac. Your notes and search queries are
turned into vectors locally and never leave your Mac.

**✨ actions** (fix grammar, make clearer, make shorter, turn into a checklist, add a title) use Apple's on-device
Foundation Models (Apple Intelligence, macOS 26 or later). The text is processed on your Mac. When you use these
actions from the browser panel, the text goes to the NoteAnywhere app on your Mac, not to a server.

**Writing Tools.** NoteAnywhere's editor allows macOS Writing Tools, a system feature that Apple provides and
controls. When you use it, Apple's privacy terms for Apple Intelligence apply.

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
  folder, pin and color label;
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

Changes to this policy are published in this file, with a new date at the top. Its history is in the repository's
git log.

## Contact

Questions or requests: timeupvishwa@gmail.com, or open an issue at
https://github.com/Vishwas3000/NoteAnywhere/issues.
