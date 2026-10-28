# Chrome Web Store listing

Field by field, in the order the Developer Dashboard asks. Everything here matches what `extension/` does today; if
the extension changes, update this and [PRIVACY.md](../PRIVACY.md) together.

**Before uploading** (release work, not copy): the manifest still says "MemoryNotes" in `name`, `description` and
`action.default_title`; the Web Store gives the extension its own id, which the Mac app's native host manifest must
list in `allowed_origins` (next to the dev id); and the panel's "Mac app not installed — run scripts/install.sh"
message should point store users to the download page instead. See the checklist in [README.md](README.md).

---

## Store listing

**Name:** NoteAnywhere

**Summary / short description** (132 characters max; this is 124):

> Your notes for the page you're on, in a panel on the page. Stored by the free NoteAnywhere app on your Mac, not on a server.

**Category:** Productivity › Workflow & Planning (alternative: Productivity › Tools)

**Language:** English

**Detailed description** (plain text; the store doesn't render Markdown):

```
NoteAnywhere shows your notes for the page you're on, in a small panel on that page.

Write a note on a GitHub repo, a docs page or a customer's site. The next time you open that page, the panel opens by itself with your notes. A page also shows the notes of the pages under it, so a site's home page lists everything you wrote anywhere on that site.

This extension is the browser half of NoteAnywhere, a free and open-source notes app for macOS. It needs the Mac app, which stores your notes on your Mac: https://github.com/Vishwas3000/NoteAnywhere/releases/latest

WHAT YOU CAN DO
• See and edit a page's notes in a panel on the page. Press Alt+Shift+N (⌥⇧N) or click the toolbar icon to show or hide it.
• Write in Markdown with a full editor: headings, lists, checklists, tables, links, #tags and dates.
• Search all your notes, by meaning and by exact words.
• Fix grammar, shorten text or turn it into a checklist with Apple Intelligence (on macOS 26; the model runs on your Mac).
• Edits sync live with the Mac app: change a note in either place and the other updates.

PRIVATE BY DESIGN
• Notes are stored by the NoteAnywhere app on your Mac, in a local database. The extension itself stores only one setting: whether the panel is widened.
• To know whether a page has notes, the extension sends the page's address (domain and path, without the query string) to the NoteAnywhere app on your Mac. It is not sent to any server.
• No analytics, no tracking, no ads.
• The panel runs in an isolated frame, so the websites you visit can't read what you type in it.

The Mac app works without this extension, with notes for apps and windows (a Slack channel, a VS Code project) as well as web pages.

Works in Chrome and Brave on macOS 15 or later.

Open source (GPL-3.0): https://github.com/Vishwas3000/NoteAnywhere
Privacy policy: https://github.com/Vishwas3000/NoteAnywhere/blob/main/PRIVACY.md
```

**Graphics** (see [assets.md](assets.md)):

- Store icon: 128×128 PNG (CWS-ICON)
- Screenshots: up to 5, 1280×800 (CWS-1 to CWS-5)
- Small promo tile: 440×280 (CWS-TILE)
- Marquee promo tile: 1400×560, optional (CWS-MARQUEE)

**Official URL / homepage:** https://github.com/Vishwas3000/NoteAnywhere

**Support URL:** https://github.com/Vishwas3000/NoteAnywhere/issues

---

## Privacy practices tab

**Single purpose description:**

> Show, write and search the user's NoteAnywhere notes for the web page they are on, in a panel on that page. Notes
> are stored by the companion NoteAnywhere app on the user's Mac, which the extension talks to through native
> messaging.

**Permission justifications:**

- **nativeMessaging**: The extension has no storage of its own for notes. It sends requests (list the notes for this
  page, save, delete, search, run an on-device text action) to the NoteAnywhere app installed on the user's Mac,
  which stores the notes in a local database. It also keeps one connection open so the app can tell open panels when
  a note changed, which keeps the panel and the app in sync.
- **activeTab**: When the user clicks the toolbar icon or presses the shortcut on a tab that was open before the
  extension was installed, the content script isn't in that tab yet. activeTab lets the extension add its panel to
  that one tab, only in response to the user's action.
- **scripting**: Used together with activeTab, for the same case: `chrome.scripting.executeScript` injects
  `content.js` into the tab the user just acted on. It is not used on any other tab and never injects remote code.
- **storage**: Remembers one preference in `chrome.storage.local`: whether the user widened the panel. No notes,
  page addresses or personal data are stored there.
- **Host permission (content script on all sites)**: The panel opens by itself on pages that have notes, and a note
  can belong to any site the user chooses, so the content script runs on every page. It only places the panel's
  frame and reads the page's address and title; it does not read or change page content.

**Remote code:** No, I am not using remote code. (The editor is bundled in the extension package.)

**Data usage.** What user data the extension collects (declare honestly; these match the code and PRIVACY.md):

| Category | Declare | Why |
|----------|---------|-----|
| Personally identifiable information | No | |
| Health information | No | |
| Financial and payment information | No | |
| Authentication information | No | Sync sign-in happens in the Mac app, not the extension |
| Personal communications | No | |
| Location | No | |
| Web history | **Yes** | The address of each page is sent to the NoteAnywhere app on the user's Mac to look up its notes; a note saves the address of the page it was written on |
| User activity | No | No keystroke, click or scroll logging; the user's own note text goes to the Mac app as notes |
| Website content | **Yes** | The page's title is saved with a note the user creates on that page |

Certify all three:

- [x] I do not sell or transfer user data to third parties, outside of the approved use cases.
- [x] I do not use or transfer user data for purposes that are unrelated to my item's single purpose.
- [x] I do not use or transfer user data to determine creditworthiness or for lending purposes.

(If the user turns on sync in the Mac app, the Mac app sends their notes to Supabase, a service provider, to sync
them between their own devices. That is part of the single purpose and is described in the privacy policy.)

**Privacy policy URL:** https://github.com/Vishwas3000/NoteAnywhere/blob/main/PRIVACY.md

---

## Distribution

- **Visibility:** Public.
- **Regions:** All.
- **Pricing:** Free.

## Notes for the reviewer (Test instructions field)

```
This extension is the browser companion of NoteAnywhere, a free open-source macOS app. It needs the Mac app, which stores the notes and is the native messaging host.

1. On a Mac (macOS 15+), install the app: https://github.com/Vishwas3000/NoteAnywhere/releases/latest, open it once.
2. Install this extension, open any page (e.g. https://github.com), click the toolbar icon, then "New note" and type.
3. Reload the page: the panel opens by itself with the note.

Without the Mac app, the panel shows a message that the Mac app isn't installed; nothing else happens and nothing is sent anywhere.
Source code: https://github.com/Vishwas3000/NoteAnywhere/tree/main/extension
```
