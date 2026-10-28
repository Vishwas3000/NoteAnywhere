# Screenshots and GIFs: shot list

Every image uses **demo content only**. Never capture the real notes database, real Slack workspaces, real chats or
real names. The posts already use the demo names below (Acme, Sam, #design-review, weather-app), so stick to them.

## Set up a clean demo machine

Use a **separate macOS user account** (System Settings ▸ Users & Groups ▸ Add User, name it "Demo"). This is the only
setup that keeps everything clean: the browser extension's native host is started by Chrome and always opens the
default notes database, so a temporary `MEMORYNOTES_DIR` would still show your real notes in the browser. A fresh
account also has no other Slack workspaces in the sidebar, no recent files, no bookmarks and no notifications.

In the Demo account:

1. Install NoteAnywhere from the DMG and the extension from the store (or `scripts/install.sh` + Load unpacked).
   Allow Accessibility. **Keep sync off.**
2. Run one search first so the model downloads (about 87 MB), then wait a few seconds so notes get indexed; the
   graph's "similar" links and meaning search need it.
3. Slack: create a free workspace named **Acme** with channels `#general`, `#design-review` and `#release`. For the DM
   shots, invite a second account you own with the display name **Sam**.
4. VS Code: a folder named **weather-app** with `index.ts` and `README.md` (any small code).
5. Chrome: a new profile with no bookmarks bar, no other extensions, the avatar hidden or neutral.
6. WhatsApp: only if you have a spare demo number; otherwise skip WhatsApp shots and don't fake one.
7. Look: light mode for the main set (one dark variant for social), a plain wallpaper, Do Not Disturb on, menu bar
   with nothing personal, Dock hidden or clean.

## Demo notes

Create these in the Demo account, in place, so each one gets its real context. Use the `@` menu for dates so they land
in the week you shoot.

| Where | Note text (Markdown) |
|-------|----------------------|
| Slack › Acme › Sam (DM) | `# Sam`<br>`- [ ] Ask about the API rate limits @<Thu>`<br>`- [ ] Share the onboarding draft`<br>`Prefers async reviews. #team` |
| Slack › Acme › design-review | `# Design review`<br>`- Sidebar groups by date, like Apple Notes`<br>`- [ ] Check dark mode contrast @<Fri> #design` |
| Slack › Acme › release | `Release checklist #release`<br>`- [x] Notarize the DMG`<br>`- [ ] Submit the extension @<Mon>` |
| VS Code › weather-app | `# weather-app`<br>`CI fails on a clean checkout: run npm ci before the build. #dev` |
| VS Code › weather-app › index.ts | `Cache the forecast for 10 minutes; the API allows 60 calls/hour. #dev/api` |
| github.com/ueberdosis/tiptap | `Pinned to 3.32. Markdown via @tiptap/markdown. #dev` |
| github.com/ueberdosis/tiptap/issues | `Watch the drag-handle issue before upgrading.` |
| developer.apple.com/documentation/foundationmodels | `On-device model, macOS 26. Check availability first. #dev/ai` |
| (plain note, ⌘N) | `# Reading list`<br>`- Local-first software (Ink & Switch)`<br>`- The Pragmatic Programmer #reading` |
| (plain note, ⌘N) | `# Trip ideas`<br>`- Lisbon in spring`<br>`- Kyoto in autumn #travel` |

Before recording the search GIF, try the query. If "why does the build break" doesn't put the weather-app note first,
change the query, not the result. Never fake a result.

## Shots

Sizes: **README / blog stills** at 2× (about 2560×1600, cropped to content); **Chrome Web Store** 1280×800;
**Product Hunt gallery** 1270×760, thumbnail 240×240; **social card** 1200×630 (X, LinkedIn, Open Graph); **GitHub
social preview** 1280×640; **dev.to cover** 1000×420. Export PNG for stills; MP4 for video, GIF for embeds that need
it (keep GIFs under 10 MB, which GitHub accepts in a README; Product Hunt and Reddit have their own upload limits,
check them in the uploader).

### Video / GIF

| Id | Scene | Length | Used in | Caption |
|----|-------|--------|---------|---------|
| V-1 | Slack: start in #general (no notes, no panel). Click **Sam** in the sidebar: the panel slides in with Sam's note. Click #design-review: the panel switches to its note. Press ⌥⇧M to hide it. | 15–25 s | README, Medium `{{HERO_GIF_URL}}`, dev.to, Reddit, X 1/7, LinkedIn, PH video | Notes come back when you return to the DM or channel. |
| V-2 | Over VS Code, press ⌥⇧Space, type "why does the build break", the weather-app note is first; press Return and it expands into an editor. | 10–15 s | Medium `{{SEARCH_GIF_URL}}`, X 4/7 | Search by meaning, on your Mac. |
| V-3 | Split screen: the Mac app and Chrome on github.com/ueberdosis/tiptap. Edit the note in the Mac app; the browser panel updates. | 10 s | dev.to (optional), X 3/7 (optional) | The browser and the app stay in sync. |
| V-4 | In a note, type `@`, the date menu opens, pick Friday; a chip appears. ⌘2 to the calendar: the line is under Planned on Friday; tick its circle and the note's checkbox ticks. | 15 s | X 5/7 (optional), PH | Type @ and pick a day. |
| V-5 | Drag a list item by its ⋮⋮ handle to another spot; then ⌘⇧↑ moves a block. | 8 s | optional | Move any block like in Notion. |

### Stills

| Id | Scene | Used in | Caption |
|----|-------|---------|---------|
| S-1 | Slack on the Sam DM with the floating panel open on the right, showing the note with its checklist and a date chip. | README hero `{{HERO_SCREENSHOT_URL}}`, PH-1 | Notes come back when you return to the DM. |
| S-2 | Chrome on github.com/ueberdosis/tiptap with the panel: the page's note plus the `↳ /issues` note. | Medium `{{BROWSER_PANEL_URL}}`, X 3/7, PH-2, CWS-1 | Notes on any web page, and its sub-pages. |
| S-3 | The ⌥⇧Space popup over VS Code with results and the key-hint footer. | PH-3 | Search everything from anywhere. |
| S-4 | Main window, Notes tab: sidebar with Folders (create "Work" and "Personal"), a Pinned note, Today / Previous 7 Days and the Tags list with counts; the note count under the title; the Sam note open with its source chip, checklist, #tag and date chip; one note with a color label. | PH-4 | A full Markdown notes app. |
| S-9 | The right-click menu open on a note in the sidebar: Open Note in New Window, Pin, Duplicate, Share, Move to, Color. | optional, PH (optional) | Organized like Apple Notes. |
| S-5 | Calendar, week view, with Planned tasks on three days (one ticked) and edits below. | Medium `{{CALENDAR_URL}}`, X 5/7, PH-5 | Dated lines and tasks land on the calendar. |
| S-6 | Graph (⌘3) with Slack, VS Code and github.com hubs, tag hubs (#dev with #dev/api under it), dashed similar links; toggles visible. | Medium `{{GRAPH_URL}}`, Reddit r/ObsidianMD `{{GRAPH_URL}}`, X 5/7, PH-6 | See how your notes connect. |
| S-7 | The ✨ menu open on the release note (macOS 26), "Turn into Checklist" highlighted, "Apple Intelligence · on this Mac" footer visible. | PH (optional), dev.to (optional) | Apple Intelligence, on-device. |
| S-8 | VS Code on `index.ts` with the panel showing "Visual Studio Code › weather-app › index.ts" notes. | optional, r/swift | Notes per project and file. |

### Chrome Web Store (1280×800, the browser in focus)

| Id | Scene | Caption |
|----|-------|---------|
| CWS-1 | S-2: the panel on the TipTap repo page with both notes. | Your notes for the page you're on, right on the page. |
| CWS-2 | The panel's search box with results across sites. | Search all your notes by meaning. |
| CWS-3 | The panel's editor with a checklist, a #tag and a date chip; the formatting toolbar showing. | A real Markdown editor. |
| CWS-4 | The ✨ menu in the browser panel. | Fix grammar or make a checklist, on your Mac. |
| CWS-5 | The Mac app's main window with the same website notes. | Every note also lives in the free Mac app. |
| CWS-TILE | 440×280: the app icon and "Notes for the page you're on". | |
| CWS-MARQUEE | 1400×560 (optional): S-2 cropped, with the icon and name. | |
| CWS-ICON | 128×128 from the app icon (`scripts/make_icon.swift` draws it at 1024). | |

### Product Hunt (1270×760)

PH-1 = S-1, PH-2 = S-2, PH-3 = S-3, PH-4 = S-4, PH-5 = S-5, PH-6 = S-6, and **PH-7**: a plain card reading
"Local SQLite · On-device AI · Sync off by default · Free, GPL-3.0". **PH-0** thumbnail 240×240: the app icon, or a
short loop of V-1 cropped to the panel.

### Social and covers

| Id | Size | Content |
|----|------|---------|
| SOC-1 | 1200×630 | S-1 cropped to Slack + panel, with "NoteAnywhere: notes that show up where they belong". Also used as Open Graph image. Light and dark variants. |
| GH-1 | 1280×640 | Same as SOC-1, for the repo's Settings ▸ Social preview. |
| DEV-1 | 1000×420 | dev.to cover `{{COVER_IMAGE_URL}}`: the panel over Slack on the left, the graph on the right. |

## Before publishing any image

Zoom in and check: the menu bar, the Dock, notification banners, browser tabs and profile avatar, Slack's workspace
rail, VS Code's title bar and recent files, the Sync settings (keep it showing "Off"), and every window title. Only
demo names should appear.

Capture with ⌘⇧5 (record selected portion), hide window shadows for stills with ⌘⇧4, Space, then Option-click.
