using NoteAnywhere.Core;

namespace NoteAnywhere.Core.Tests;

public class NoteActionsTests
{
    static Note N(string text, string target = "", NoteKind kind = NoteKind.Url, string label = "", double at = 1, bool locked = false) =>
        new() { Kind = kind, Target = target, Label = label, Text = text, UpdatedAt = at, Locked = locked };

    [Fact]
    public void APageFromAHighlightLinksBack()
    {
        var parent = N("Sync [notes]\nbody");
        Assert.Equal($"Why does sync lag?\n\n↖ [Sync [notes\\]](note://{parent.Id})\n\n", NoteActions.PageText("Why does\nsync lag?", parent));
        Assert.Equal("Alone\n\n", NoteActions.PageText("Alone", null));
    }

    [Fact]
    public void PlacesAndTags()
    {
        Assert.Equal("Slack › Acme › Sam (DM)", NoteActions.Place(N("", "com.tinyspeck.slackmacgap/Acme/Sam (DM)", NoteKind.App, "Slack")));
        Assert.Equal("github.com/a/b", NoteActions.Place(N("", "github.com/a/b")));
        Assert.Equal([("work", 2), ("home", 1)], NoteActions.TagCounts([N("a #work"), N("b #work #home")]));
    }

    [Fact]
    public void WordsSearchNewestFirst()
    {
        var old = N("Sync lag\nsupabase sockets", at: 1);
        var recent = N("Notes on sync\nsockets idle out", at: 2);
        var other = N("Groceries\nmilk", at: 3);
        Assert.Equal([recent, old], NoteActions.Search([old, recent, other], "SYNC sockets"));
        Assert.Equal([recent], NoteActions.Search([old, recent, other, N("#later")], "idle"));
        Assert.Equal([other], NoteActions.Search([old, other, N("x #shop")], "milk"));
        Assert.Empty(NoteActions.Search([N("Secret\nbank pin", locked: true)], "bank"));  // a locked note's text stays closed
    }

    [Fact]
    public void TagQueries()
    {
        var a = N("a #project/notes", at: 1);
        var b = N("b #project", at: 2);
        Assert.Equal([b, a], NoteActions.Search([a, b, N("c #other")], "#project"));
    }
}

/// The Mac's browserTitleNotesShowOnlyOnTheirTitle: which notes the panel shows for the place in front.
public class PanelNotesTests
{
    [Fact]
    public void BrowserTitleNotesShowOnlyOnTheirTitle()
    {
        var title = new Note { Kind = NoteKind.App, Target = "com.brave.Browser/Site/Page", Label = "Brave" };
        var page = new Note { Kind = NoteKind.Url, Target = "example.com/docs", Label = "Docs" };
        var chat = new Note { Kind = NoteKind.App, Target = "com.tinyspeck.slackmacgap/Acme/general", Label = "Slack" };
        Note[] all = [title, page, chat];
        // Brave's window with an empty title: only the app is known. Its title notes must not pop up.
        Assert.Empty(NoteActions.Shown(all, "com.brave.Browser", null, inBrowser: true));
        Assert.Equal([title.Id, page.Id], NoteActions.Shown(all, "com.brave.Browser/Site/Page", "example.com", inBrowser: true).Select(n => n.Id));
        // Other apps keep "parents see children".
        Assert.Equal([chat.Id], NoteActions.Shown(all, "com.tinyspeck.slackmacgap/Acme", null, inBrowser: false).Select(n => n.Id));
        Assert.Contains("com.microsoft.edgemac", NoteActions.Browsers);
    }
}
