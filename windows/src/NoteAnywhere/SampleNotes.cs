using NoteAnywhere.Core;

namespace NoteAnywhere;

/// --seed-sample-notes, for CI's screenshots: a few notes of each kind, added only to an empty store, so it never mixes
/// with anyone's notes.
static class SampleNotes
{
    public static void SeedIfEmpty()
    {
        var model = NotesModel.Shared;
        if (model.Notes.Count > 0) return;
        var work = model.AddFolder("Work");
        var welcome = model.Add(NoteKind.Url, "", "", text: "Welcome to NoteAnywhere for Windows\n\nNotes that wait for you: they open beside the app, chat or page they're about.\n\n- [x] Install NoteAnywhere\n- [ ] Write a note in Slack\n- [ ] Add the browser extension");
        model.Update(welcome.Id, n => n with { Pinned = true });
        var release = model.Add(NoteKind.Url, "", "", work.Id, "Release checklist\n#launch\n\nBugs:\n\n- [x] Google sign-in\n- [ ] Apple sign-in\n\nFeatures:\n\n- [ ] Find in a note\n- [ ] A calmer window");
        model.Update(release.Id, n => n with { Color = NoteColor.Yellow });
        model.Add(NoteKind.App, "com.tinyspeck.slackmacgap/Acme/design-review", "Slack", text: "Design review\nMove the tab bar under the title, then ask Sam");
        var cache = model.Add(NoteKind.Url, "github.com/vercel/next.js", "Next.js", text: "Next.js caching\nuse cache and unstable_cache #web");
        model.Update(cache.Id, n => n with { Starred = true });
        // CI opens probe.txt in Notepad and expects the panel to open with this note.
        model.Add(NoteKind.App, "win.notepad/probe.txt", "Notepad", text: "Notes on probe.txt\nThis note waits beside Notepad whenever probe.txt is open.\n\n- [ ] Check the panel opens by itself");
        model.Add(NoteKind.Url, "arxiv.org/abs/1706.03762", "Attention Is All You Need", text: "Attention is all you need\nWhat is an RNN, and what are its limits?");
    }
}
