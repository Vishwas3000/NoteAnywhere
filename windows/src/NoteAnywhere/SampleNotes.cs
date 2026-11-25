using System.Globalization;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// --seed-sample-notes, for CI's screenshots: a few notes of each kind, added only to an empty store, so it never mixes
/// with anyone's notes. Their dated lines are around today, so the calendar has something to show whenever CI runs.
static class SampleNotes
{
    public static void SeedIfEmpty()
    {
        var model = NotesModel.Shared;
        if (model.Notes.Count > 0) return;
        var work = model.AddFolder("Work");
        var welcome = model.Add(NoteKind.Url, "", "", text: $"Welcome to NoteAnywhere for Windows\n\nNotes that wait for you: they open beside the app, chat or page they're about.\n\n- [x] Install NoteAnywhere\n- [ ] Write a note in Slack\n- [ ] Add the browser extension {On(1)}\n\n#noteanywhere");
        model.Update(welcome.Id, n => n with { Pinned = true });
        var release = model.Add(NoteKind.Url, "", "", work.Id, $"Release checklist\n\n#launch #noteanywhere\n\nBugs:\n\n- [x] Google sign-in {On(-1)}\n- [ ] Apple sign-in {On(2)}\n\nFeatures:\n\n- [ ] Find in a note\n- [ ] A calmer window\n\nBeta on the store {On(4)}{{green}}");
        model.Update(release.Id, n => n with { Color = NoteColor.Yellow });
        model.Add(NoteKind.App, "com.tinyspeck.slackmacgap/Acme/design-review", "Slack", text: $"Design review\n\nMove the tab bar under the title, then ask Sam {On(0)}\nFor the [Release checklist](note://{release.Id}) #launch #design");
        var cache = model.Add(NoteKind.Url, "github.com/vercel/next.js", "Next.js", text: $"Next.js caching\n\nuse cache and unstable_cache #web\n- [ ] Try cacheLife on the docs site {On(3)}");
        model.Update(cache.Id, n => n with { Starred = true });
        // CI opens probe.txt in Notepad and expects the panel to open with this note.
        model.Add(NoteKind.App, "win.notepad/probe.txt", "Notepad", text: "Notes on probe.txt\n\nThis note waits beside Notepad whenever probe.txt is open.\n\n- [ ] Check the panel opens by itself");
        model.Add(NoteKind.Url, "arxiv.org/abs/1706.03762", "Attention Is All You Need", text: "Attention is all you need\n\nWhat is an RNN, and what are its limits? #ml #reading");
        // Seven days around today, so the week on screen always has a range, and the month shows one meeting a new week.
        model.Add(NoteKind.Url, "", "", text: $"Plans\n\nTeam offsite {On(-1)} - {On(5)}{{purple}}\nDentist {On(1)}\n\n#personal");
    }

    /// "@2026-11-27" for `days` from today.
    static string On(int days) => "@" + DateTime.Today.AddDays(days).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
}
