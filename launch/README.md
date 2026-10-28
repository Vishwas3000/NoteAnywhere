# NoteAnywhere launch kit

Everything to announce NoteAnywhere. Nothing here has been posted; each file is ready to paste once its `{{…}}`
placeholders are filled.

| File | What it is |
|------|------------|
| [medium.md](medium.md) | Story post, about 1,600 words, with title options, subtitle, tags and image plan |
| [devto.md](devto.md) | Technical deep-dive with dev.to front matter (`published: false`) |
| [reddit-macapps.md](reddit-macapps.md) | r/macapps post, plus variants for r/opensource, r/SideProject, r/swift, r/ObsidianMD |
| [show-hn.md](show-hn.md) | Show HN title and first comment |
| [product-hunt.md](product-hunt.md) | Tagline, description, maker comment, gallery order |
| [x-thread.md](x-thread.md) | 7-post thread |
| [linkedin.md](linkedin.md) | LinkedIn post |
| [chrome-web-store.md](chrome-web-store.md) | Store listing, single purpose, permission justifications, data disclosures, reviewer notes |
| [assets.md](assets.md) | Demo setup, demo notes and the shot list with sizes and captions |
| [../PRIVACY.md](../PRIVACY.md) | Privacy policy; the Web Store links to it |

## Before launch

Release work (not in this kit, but the launch depends on it):

- [ ] Notarized DMG published as the latest GitHub Release.
- [ ] The DMG's app registers the native messaging host for Chrome and Brave on first launch, with the **Web Store
      extension id** in `allowed_origins` (today only `scripts/install.sh` registers it, for the unpacked dev id).
      Without this, the store extension can't reach the app.
- [ ] Extension manifest: `name`, `description` and `action.default_title` say NoteAnywhere. Check whether the store
      accepts the manifest's `key` field; if not, strip it from the uploaded zip only (dev builds need it).
- [ ] The extension's "Mac app not installed — run scripts/install.sh" message points store users to the Releases
      page instead.
- [ ] User-visible app names say NoteAnywhere (window title, menu items like "Quit MemoryNotes", the "MemoryNotes
      Cloud" sync option), as decided in D36.
- [ ] Extension submitted to the Chrome Web Store with [chrome-web-store.md](chrome-web-store.md). Review can take
      several days, and content scripts on all sites often mean a longer review, so submit first.

Repo hygiene:

- [ ] **Real names in the repo.** A real colleague's name and a real workspace name appear in code comments
      (`WindowContext.swift`, `NotesWindow.swift`), tests (`WindowContextTests.swift`, `GraphTests.swift`,
      `NoteDatesTests.swift`) and `docs/DECISIONS.md` (D23), and in git history. Replace them with demo names before
      announcing; decide whether the history matters to you.
- [ ] `PRIVACY.md`, `README.md` and `CONTRIBUTING.md` merged to `main`, so the links resolve.
- [ ] GitHub repo: description ("Mac notes that show up in the app, chat or web page they're about"), topics
      (`macos`, `swift`, `swiftui`, `notes`, `chrome-extension`, `local-first`, `apple-intelligence`), social preview
      image (assets.md, GH-1), release notes on the DMG release.
- [ ] Screenshots and GIFs captured in a clean Demo account ([assets.md](assets.md)).
- [ ] The whole first run tested in that clean account: download, Gatekeeper, Accessibility prompt, extension,
      first note, first search (model download).

## Placeholders to fill

| Placeholder | Where | What |
|-------------|-------|------|
| `{{CHROME_WEB_STORE_URL}}` | ../README.md, every post | The extension's store page, once approved |
| `{{CONTACT_EMAIL}}` | ../PRIVACY.md (twice) | An address you'll answer privacy and deletion requests at; a personal project address, not a work one |
| `{{HERO_SCREENSHOT_URL}}` | ../README.md | S-1. Commit the image (e.g. `docs/images/hero.png`) and use the relative path |
| `{{HERO_GIF_URL}}` | medium.md, devto.md, reddit-macapps.md | V-1, uploaded in each site's editor |
| `{{BROWSER_PANEL_URL}}` | medium.md | S-2 |
| `{{SEARCH_GIF_URL}}` | medium.md | V-2 |
| `{{GRAPH_URL}}` | medium.md, reddit-macapps.md (r/ObsidianMD) | S-6 |
| `{{CALENDAR_URL}}` | medium.md | S-5 |
| `{{COVER_IMAGE_URL}}` | devto.md | DEV-1, 1000×420 |
| `{{DEVTO_URL}}` | reddit-macapps.md (r/swift) | The published dev.to post |

Find any left with `grep -rn "{{" launch PRIVACY.md README.md`.

## Posting order

Spread it over about ten days. Each place brings questions and bug reports; leave time to answer and fix between
them. Times assume US daylight saving has ended (it ends 1 November 2026): ET = UTC−5, PT = UTC−8, IST = UTC+5:30.
"Best times" are common advice, not rules.

| Day | Where | When | Notes |
|-----|-------|------|-------|
| 0 | Chrome Web Store submission, DMG release, repo polish | a week ahead | Everything else links to these |
| 1 (Tue) | dev.to, then Medium | morning | Publish the long posts first so later posts can link them. On Medium, add to a publication if one accepts it. Set dev.to `published: true` |
| 1 | X thread, LinkedIn | 8–10 am ET (6:30–8:30 pm IST) | Pin the X thread |
| 2 (Wed) | Show HN | 8–9 am ET (6:30–7:30 pm IST) | Stay for 3–4 hours to answer |
| 3 (Thu) | r/macapps | 8–11 am ET (6:30–9:30 pm IST) | Reply to every comment the first day |
| 4–7 | r/SideProject, r/opensource, r/swift, r/ObsidianMD | one per day, US morning | r/swift links the dev.to post; r/ObsidianMD only where its rules allow |
| 8–10 (Tue–Thu) | Product Hunt | 12:01 am PT (1:31 pm IST) | After fixing what HN and Reddit found. A weekend launch is quieter but less crowded |

## Rules to respect

- **Hacker News, Show HN** ([rules](https://news.ycombinator.com/showhn.html)): it must be something people can try
  now, without a signup; the title starts with "Show HN:"; you must be around to discuss it; never ask anyone to
  upvote or comment, and don't post from a second account. Link the repo, not a landing page.
- **r/macapps:** say you're the developer, use the developer flair, state that it's free. Check the sidebar for the
  current self-promotion rules and any rule about AI-assisted apps; the post has an optional disclosure line for
  that. One post; don't repost if it doesn't take off.
- **Reddit in general:** read each subreddit's rules before posting; don't post the same link to several subreddits
  on the same day; take part in threads beyond your own posts. Reddit's long-standing guidance is that
  self-promotion should be a small part of what you post.
- **r/ObsidianMD:** about Obsidian only; other apps usually belong in a pinned self-promotion or showcase thread. If
  unsure, ask the moderators first.
- **r/swift, r/opensource:** lead with the code and what's interesting about it, not the download.
- **dev.to:** a technical article is welcome; a pure ad isn't. The post is the former.
- **Medium:** if you publish the same story elsewhere first, set the canonical link.
- **Product Hunt:** don't ask for upvotes (it penalises vote rings); you can tell people you launched.
- **Chrome Web Store:** the listing, the privacy tab and PRIVACY.md must match the extension's real behaviour. If the
  extension changes what it reads or sends, update all three before publishing the update.

## Disclosure about AI

The Medium, dev.to, Show HN, r/SideProject, X and LinkedIn copy say plainly that NoteAnywhere was built with heavy help from
Claude Code, and point to `docs/DECISIONS.md`. The r/macapps post keeps it to an optional line, for the sidebar
to decide. Keep it that way: these audiences ask, and a straight answer up front goes over better than one dragged
out in the comments.
