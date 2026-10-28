<!--
EDITOR'S NOTES: delete this block before publishing.

Title (chosen): Why I built a notes app that knows which Slack DM you're in

Alternative titles:
1. Notes that wait for you in the right Slack channel
2. Notes that know where you are: a local-first Mac app for context
3. A Mac notes app that follows you from app to app, and page to page

Subtitle: NoteAnywhere ties a note to the app, chat, project or web page you were in, and brings it back when you
return. Free, open source and local-first.

Suggested tags (Medium allows 5): Mac, Productivity, Note Taking, Open Source, Apple Intelligence

Images (shot list and sizes in launch/assets.md; demo content only):
- {{HERO_GIF_URL}}: a Slack DM in a demo workspace opens and the floating panel slides in with that DM's notes.
  Use it as the header image, or as the first image after the opening.
- {{BROWSER_PANEL_URL}}: the browser panel on a GitHub repo page, with a ↳ note from a sub-page.
- {{SEARCH_GIF_URL}}: ⌥⇧Space over another app, a reworded query finding the right note.
- {{GRAPH_URL}}: the knowledge graph with app/site hubs, tag hubs and dashed "similar meaning" links.
- {{CALENDAR_URL}}: the calendar's day view with "Planned" tasks, one being ticked.

Canonical link: if you also post this elsewhere, set Medium's canonical URL to the first place it appeared.
-->

# Why I built a notes app that knows which Slack DM you're in

*NoteAnywhere ties a note to the app, chat, project or web page you were in, and brings it back when you return.*

You're in a DM with Sam. Halfway through, you remember there were three things you wanted to ask about the release.
You wrote them down two days ago. They're in a notes app, in a note called something like "Sam stuff", under forty
other notes. You find it after the conversation is over.

Or you're back in a repo you haven't opened for a month. The last time you were here, you worked out why the build
breaks on a clean checkout. You wrote that down too. Somewhere.

Notes apps are good at keeping things. They're bad at knowing when you need them. A note about a person, a project or
a web page is most useful in one place: when you're looking at that person, project or page again.

That's the whole idea behind NoteAnywhere, a free and open-source notes app for the Mac. You write a note while
you're somewhere. When you come back, the note is there.

![A Slack DM opens and its notes appear in a small floating panel]({{HERO_GIF_URL}})

## The first version only knew the app

The first version was simple: a floating panel that showed notes for the app in front. Switch to Xcode, see your
Xcode notes. Switch to Figma, see your Figma notes. A Chrome extension did the same for websites.

It worked, and it was not enough. "Slack" isn't a place. Slack is fifty places. A note about the design review has
nothing to do with a DM with Sam; they just live in the same app.

So the next question was how a Mac app can know which channel you're in.

## Reading the window title

It turns out most apps tell you, in the window title. Slack's looks something like
"Sam (DM) - Acme - 8 new items - Slack". VS Code's says "index.ts — weather-app — Visual Studio Code". Browsers put
the page title there.

NoteAnywhere reads the front window's title through the macOS Accessibility API and turns it into a path, from
broad to narrow: Slack › Acme › Sam (DM). It drops what changes without the place changing, like unread counts,
"8 new items" or the dot that means a file isn't saved. There's no special parser for Slack. The same few rules work
for every app, which is the only way this works for apps I've never seen.

The path gives you something nice for free: a broader place sees everything under it. Open the Acme workspace and you
see notes from all its channels. Open one DM and you see just that DM's notes.

Then WhatsApp broke it. WhatsApp's window title is just "WhatsApp", whichever chat is open. So for apps like that,
NoteAnywhere keeps a tiny table naming the one element on screen that shows the open conversation (for WhatsApp, the
chat header) and reads only that. It skips the message list on purpose. It needs to know who you're talking to, never
what was said.

## The web, and keystrokes that went missing

On the web, a note belongs to a page, and a page also sees the notes of the pages under it. Write a note on a repo's
issues page and it shows up on the repo's front page too, with a small ↳ link back to where you wrote it.

![The browser panel on a GitHub repo, with a note from one of its sub-pages]({{BROWSER_PANEL_URL}})

The first browser panel was injected straight into the page. On a few sites, typing into a note sent the keystrokes
into the site's own text box instead. Pages can do a lot with focus and keyboard events, and some do.

The fix was to move the whole panel into an isolated extension frame, where the page can't see its keystrokes or
touch its styles. I tested it against a page that redirects every keystroke to its own box, and the note kept the
typing every time. One kind of page can still pull focus back: one that re-focuses itself whenever anything else gets
focus. That's written down as a known limit rather than papered over.

The panel and the Mac app stay in sync live. Edit a website note in the Mac app and the open tab updates. Edit it in
the tab and the Mac app updates.

## Search by meaning, without sending notes anywhere

Once notes are spread across apps and pages, you need to find them from anywhere. ⌥⇧Space opens a search box over
whatever you're doing.

I wanted search by meaning: "the thing about flaky builds" should find a note that says "CI fails on a clean
checkout". The obvious choice was Apple's built-in sentence embeddings, since they ship with macOS. On a small test, 8
notes and 7 reworded queries, they put the right note first 2 times out of 7. A small open model, all-MiniLM-L6-v2,
got 6 out of 7. That's a tiny test, but the gap was big enough to decide.

So NoteAnywhere runs MiniLM on your Mac. It downloads once, on your first search (about 87 MB), and after that your
notes and queries never leave the machine. Exact words count too, so names and non-English text still match.
Searching for a #tag lists exactly the notes with that tag.

![⌥⇧Space over another app, finding a note by what it means rather than its words]({{SEARCH_GIF_URL}})

## Apple Intelligence, on the Mac

The same rule applied to writing help. On macOS 26, the ✨ menu in the editor fixes spelling and grammar, makes a
note clearer or shorter, turns it into a checklist, or gives it a title. It uses Apple's on-device Foundation Models,
so it's free and the text stays on your Mac. It works from the browser panel too: the extension hands the text to the
Mac app, which runs the model. macOS Writing Tools work in the editor as well.

## Everything that grew around it

A notes app you use every day collects features. I tried to borrow habits people already have instead of inventing
new ones.

From Apple Notes: the look. A sidebar grouped into Today, Yesterday and Previous 7 Days, a yellow accent, round
checkboxes. ⌘N makes a plain note that isn't tied to anything, and you can attach a website to it later, or take it
away.

From Obsidian: #tags, nested like `#area/topic`, and a knowledge graph. Each note is a dot joined to its app or site,
its tags, the notes it links to, and notes with a similar meaning. That last kind of link comes from the search model,
so the graph shows connections you never made by hand.

![The knowledge graph: notes joined to their apps, sites, tags and similar notes]({{GRAPH_URL}})

From Notion: a ⋮⋮ handle beside every block to drag it somewhere else, and an "@" menu for dates. Type @ and pick
Today, Tomorrow, a day in the coming week, or "Pick a date…". Typing `@today` or `@fri` and a space works too. A dated
line shows up on the calendar under "Planned", and if it's a checklist item, you can tick it right there and the note
updates.

The calendar also shows what you edited each day, with each note as it was on that day.

![The calendar's day view: planned tasks with tick circles, then the day's edits]({{CALENDAR_URL}})

## What it reads, and what it doesn't

An app that asks for the Accessibility permission should be plain about why, so here it is.

NoteAnywhere reads the title of the front window and, for WhatsApp, the name on the open chat's header. It doesn't
read message contents, keystrokes or your screen, and it doesn't ask for Screen Recording. Titles are used to decide
which notes to show; one is saved only when you create a note in that place.

Your notes live in a SQLite database on your Mac. Sync is optional and off by default. If you want your notes on more
than one device, you can turn it on and sign in with a link sent to your email. It goes through Supabase, and the
privacy policy says plainly that it isn't end-to-end encrypted. There are no analytics.

It's also light. In my measurements it sits at about 0% CPU when idle and uses 37 to 65 MB of memory.

## The honest limits

Window titles carry names, not ids, so renaming a Slack channel starts a new place for its notes. The extension is
for Chrome and Brave only. The app needs macOS 15 or later, and the ✨ actions need macOS 26 and a Mac that supports
Apple Intelligence.

## How it was built

NoteAnywhere was built quickly, with a lot of help from Claude Code. I made the product calls; the AI did much of the
typing and proposed many of the details. The repo keeps a decision log with every choice, why it was made, what was
rejected, and whether it was my call or the AI's proposal. If you're curious how a project like this actually comes
together, that file is the most honest record of it.

## What's next

An iPhone app is in progress, with a Share extension and a Safari extension, so you can save a note from anywhere on
the phone. So is an Apple Notes–style right-click menu: pin, lock with Touch ID, folders, duplicate, share and color
labels. iCloud sync is planned, for people who'd rather not use a separate service.

## Try it

NoteAnywhere is free and open source under GPL-3.0.

- Download for Mac: https://github.com/Vishwas3000/NoteAnywhere/releases/latest
- Chrome extension (works in Brave too): {{CHROME_WEB_STORE_URL}}
- Source code: https://github.com/Vishwas3000/NoteAnywhere

If you try it, I'd love to hear where it helps, where it gets in the way, and which apps' windows it reads wrong.
GitHub issues are the best place for that, or leave a response here.
