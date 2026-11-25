using System.Text.Json;

namespace NoteAnywhere.Core.Tests;

/// Tests/MemoryNotesTests/NoteTextTests.swift, and more: where the Mac has no test, the values are what its Note.swift returned for the same text.
public class NoteTextTests
{
    static Note Text(string text, double updatedAt = 0) => new() { Kind = NoteKind.Url, Target = "", Label = "", Text = text, UpdatedAt = updatedAt };

    // Escaped so they can be seen: the combining acute and dot above, the zero-width space and joiners, the no-break space.
    const string Acute = "\U00000301", Dot = "\U00000307", ZeroWidthSpace = "\U0000200B", NonJoiner = "\U0000200C", Joiner = "\U0000200D";

    [Theory]
    [InlineData("# Title", "Title")]
    [InlineData("- [ ] Implement the key rotation", "Implement the key rotation")]
    [InlineData("- [x] done", "done")]
    [InlineData("1. Cross entropy and **how** it works", "Cross entropy and how it works")]
    [InlineData("> quoted *it* ~~gone~~ `code`", "quoted it gone code")]
    [InlineData("See [the docs](https://example.com) and ![pic](a.png)", "See the docs and pic")]
    [InlineData("snake_case_name stays", "snake_case_name stays")]
    [InlineData("2 * 3 = 6", "2 * 3 = 6")]
    [InlineData("| A | B |", "A  B")]
    [InlineData("| --- | --- |", "")]
    [InlineData("---", "")]
    // Link cards and mentions (Notion-style previews) read as their titles; the card's pictures as nothing.
    [InlineData("> [!bookmark] [Quick Start – React](https://react.dev/learn)", "Quick Start – React")]
    [InlineData("> Welcome to the React docs!", "Welcome to the React docs!")]
    [InlineData("> ![](noteimage:abc \"icon\") ![](noteimage:def)", "")]
    [InlineData("See [Quick Start – React](https://react.dev/learn \"mention noteimage:abc\") first", "See Quick Start – React first")]
    // Foundation's whitespace: a zero-width space trims, a vertical tab in plain prose doesn't.
    [InlineData(ZeroWidthSpace + "zero width", "zero width")]
    [InlineData("\u000Bvt", "\u000Bvt")]
    public void PlainLine(string markdown, string expected) => Assert.Equal(expected, Note.Plain(markdown));

    [Fact]
    public void TitleAndPreview()
    {
        var note = new Note { Kind = NoteKind.App, Target = "x", Label = "X", Text = "\n# Plan\n\n- [ ] one\n```\ncode\n```\n- two" };
        Assert.Equal("Plan", note.Title);
        Assert.Equal("one code two", note.Preview);
        Assert.Equal("New Note", new Note { Kind = NoteKind.App, Target = "x", Label = "X" }.Title);
        Assert.False(Text("").HasSource);  // a note without a source shows no source line
    }

    [Fact]
    public void APagesLinkBackIsNotItsText()
    {
        var page = Text("Why does sync lag?\n\n↖ [Sync [notes\\]](note://abc)\n\n");
        Assert.Equal("Why does sync lag?", page.Title);
        Assert.Equal("", page.Preview);
        Assert.Equal("Supabase closes idle sockets.", (page with { Text = page.Text + "Supabase closes idle sockets." }).Preview);
    }

    [Theory]
    [InlineData("https://www.github.com/vercel/next.js/", "github.com/vercel/next.js")]
    [InlineData("https://GitHub.com/?tab=1#top", "github.com")]
    [InlineData("http://localhost:3000/a%20b", "localhost:3000/a%20b")]
    [InlineData("mailto:someone@example.com", "")]
    // What the Mac reads from a browser's address bar, with "https://" in front (browserAddressBarIsThePage).
    [InlineData("https://github.com/vercel/next.js?tab=readme#top", "github.com/vercel/next.js")]
    [InlineData("https://www.Example.com/", "example.com")]
    [InlineData("https://example.com", "example.com")]
    [InlineData("https://en.wikipedia.org/wiki/Café", "en.wikipedia.org/wiki/Caf%C3%A9")]
    [InlineData("https://localhost:3000/app/", "localhost:3000/app")]
    // D70: the query that names the page stays (pageKeyKeepsTheQueryThatNamesThePage).
    [InlineData("https://www.youtube.com/watch?v=9GHCiiDLHQ4&t=42s&list=PL1", "youtube.com/watch?v=9GHCiiDLHQ4")]
    [InlineData("https://www.youtube.com/results?search_query=attention+is+all", "youtube.com/results?search_query=attention%20is%20all")]
    [InlineData("https://www.google.co.in/search?q=sqrt(dk)+softmax&sca=1", "google.co.in/search?q=sqrt(dk)%20softmax")]
    [InlineData("https://www.youtube.com/watch", "youtube.com/watch")]
    [InlineData("https://github.com/vercel/next.js?tab=readme", "github.com/vercel/next.js")]
    [InlineData("https://example.com/search?q=x", "example.com/search")]
    // As the Mac's: an escaped "+" stays one, a stray "%" is escaped, bytes that aren't UTF-8 drop the query.
    [InlineData("https://www.google.com/search?q=a%2Bb+c", "google.com/search?q=a%2Bb%20c")]
    [InlineData("https://www.google.com/search?q=%ZZ", "google.com/search?q=%25ZZ")]
    [InlineData("https://www.google.com/search?q=%FF", "google.com/search")]
    [InlineData("https://www.google.com/search?q=it's+(a)*~!", "google.com/search?q=it's%20(a)*~!")]
    [InlineData("https://www.youtube.com/watch/?v=abc", "youtube.com/watch?v=abc")]
    [InlineData("https://[::1]:8080/x", "[::1]:8080/x")]
    // Unlike the Mac (m%c3%bcnchen.de), as the browser's location.host spells it.
    [InlineData("https://münchen.de/x", "xn--mnchen-3ya.de/x")]
    public void PageTargets(string address, string target) => Assert.Equal(target, Note.PageTarget(new Uri(address)));

    [Fact]
    public void ObsidianTags()
    {
        var note = Text("""
            # Heading is not a tag
            Plan for #ML and #ml again, #project/notes, (#paren) and #2024.
            `#code` and [link](https://x.com/#anchor) and a#mid
            ```
            #fenced
            ```
            - [ ] ship #release-1
            """);
        Assert.Equal(["ml", "project/notes", "paren", "release-1"], note.Tags);
        Assert.True(note.HasTag("project") && note.HasTag("project/notes") && !note.HasTag("proj"));
    }

    /// Swift's \w and [^\W\d] are Unicode's, and its strings compare canonically; .NET's differ (see Note.Word).
    [Fact]
    public void TagsInEveryScript()
    {
        Assert.Equal(["कार्य", "हिंदी", "தமிழ்", "ગુજરાતી", "বাংলা"], Note.TagsIn("#कार्य #हिंदी #தமிழ் #ગુજરાતી #বাংলা"));
        Assert.Equal(["café", "über-cool", "naïve"], Note.TagsIn("#café #cafe" + Acute + " #über-cool #naïve"));
        Assert.Equal(["日本語", "한국어", "привет", "ελλάδα", "עברית", "العربية", "ไทย"], Note.TagsIn("#日本語 #한국어 #Привет #Ελλάδα #עברית #العربية #ไทย"));
        Assert.Equal(["i" + Dot + "stanbul", "σοφια", "straße", "ßig", "ﬁle"], Note.TagsIn("#İstanbul #ΣΟΦΙΑ #straße #ẞIG #ﬁle"));
        Assert.Equal(["ⓐbc", "x²", "一个", "三月", "a٣", "क१"], Note.TagsIn("#Ⓐbc #½ #x² #Ⅻ #一 #一个 #三月 #٣٤٥ #a٣ #१२३ #क१"));
        Assert.Equal(["می" + NonJoiner + "خواهم", "ශ්" + Joiner + "රී", "tag", "a"], Note.TagsIn("#می" + NonJoiner + "خواهم #ශ්" + Joiner + "රී #tag😀 #😀 #a😀b"));
        Assert.Equal(["a_b", "_", "a-b", "-a", "a/b", "a", "2024a", "ab", "ａｂｃ"],
            Note.TagsIn("#a_b #_ #a-b #-a #a/b/ #/a #a/ #2024 #2024a #a#b #a.b #a'b #ab‿cd #ab＿cd #ａｂｃ"));
        Assert.Equal(["paren", "bracket", "brace", "comma", "semi", "colon", "bang", "q"],
            Note.TagsIn("(#paren) [#bracket] {#brace} x,#comma x;#semi x:#colon x!#bang x?#q a#mid # heading ##double"));
        Assert.True(Text("#cafe" + Acute + "/menu").HasTag("café"));
    }

    /// D77: "+ Tag" writes plain #tags where they disturb nothing, and ✕ takes them out again.
    [Fact]
    public void TagChipsEditTheText()
    {
        Assert.Equal("project-x", Note.TagName(" Project X "));
        Assert.Equal("noteanywhere/bugs", Note.TagName("#NoteAnywhere/Bugs"));
        Assert.True(Note.TagName("2024") == null && Note.TagName("#") == null && Note.TagName("") == null);

        var one = Note.Adding("noteanywhere", "Bugs\n- sync doubles notes");
        Assert.Equal("Bugs\n- sync doubles notes\n\n#noteanywhere", one);
        var two = Note.Adding("bug", one);
        Assert.Equal("Bugs\n- sync doubles notes\n\n#noteanywhere #bug", two);  // joins the line of tags
        Assert.Equal(two, Note.Adding("bug", two));  // already tagged
        Assert.Equal("#x", Note.Adding("x", ""));
        Assert.Equal("Bugs\n- sync doubles notes\n\n#bug", Note.Removing("noteanywhere", two));
        Assert.Equal("Bugs\n- sync doubles notes", Note.Removing("bug", Note.Removing("noteanywhere", two)));  // back to the text before tagging

        // In writing only the "#" goes; code, link addresses, fenced blocks and other tags stay as they were.
        var prose = """
            Fixed the #NoteAnywhere sync, see `#noteanywhere` and [x](https://a.com/#noteanywhere)
            ```
            #noteanywhere
            ```
            #noteanywhere/ios
            """;
        Assert.Equal("""
            Fixed the NoteAnywhere sync, see `#noteanywhere` and [x](https://a.com/#noteanywhere)
            ```
            #noteanywhere
            ```
            #noteanywhere/ios
            """, Note.Removing("noteanywhere", prose));
        Assert.Equal(["noteanywhere/ios"], Note.TagsIn(Note.Removing("noteanywhere", prose)));
    }

    [Fact]
    public void TagChipsInOtherScripts()
    {
        Assert.Equal("hindi-कार्य", Note.TagName("Hindi कार्य"));
        Assert.Equal("i" + Dot + "zmir", Note.TagName("İzmir"));
        Assert.Equal("x-y", Note.TagName("x\U000000A0y"));
        Assert.Null(Note.TagName("x" + ZeroWidthSpace + "y"));
        Assert.Null(Note.TagName("#a#b"));
        Assert.Equal("Task कार्य done\n#x", Note.Removing("कार्य", "Task #कार्य done\n#कार्य #x"));
        Assert.Equal("Visit İstanbul", Note.Removing("i" + Dot + "stanbul", "Visit #İstanbul"));
        Assert.Equal("x a, a. (a) a/ #ab", Note.Removing("a", "x #a, #a. (#a) #a/ #ab"));
        Assert.Equal("#a", Note.Removing("a/b", "#a/b #a #A/B/"));
        Assert.Equal("Text", Note.Removing("a", "Text\n   \n#a"));
        Assert.Equal("Text" + ZeroWidthSpace + "\n\n#x", Note.Adding("x", "Text" + ZeroWidthSpace));
        Assert.Equal("Menu #cafe" + Acute, Note.Adding("café", "Menu #cafe" + Acute));  // the same tag, spelt the other way
    }

    [Fact]
    public void RelatedNotesShareTags()
    {
        var bugs = Text("Bugs\n#noteanywhere #bug", updatedAt: 1);
        var features = Text("Features\n#noteanywhere", updatedAt: 3);
        var elsewhere = Text("Bugs elsewhere\n#bug #flam", updatedAt: 2);
        var triage = Text("Triage\n#noteanywhere #bug", updatedAt: 0);
        var groceries = Text("Groceries");
        var related = Note.Related(bugs, [bugs, features, elsewhere, triage, groceries]);
        Assert.Equal([triage.Id, features.Id, elsewhere.Id], related.Select(r => r.Note.Id));  // most shared first, then newest
        Assert.Equal(["noteanywhere", "bug"], related[0].Shared);
        Assert.Empty(Note.Related(groceries, [bugs, groceries]));
    }

    [Fact]
    public void NotesFromTheBrowser()
    {
        // The browser's shape: the newer fields missing, and an id from before D76 in capitals.
        var note = JsonSerializer.Deserialize<Note>("""{"id":"ABC-1","kind":"url","target":"x.com","label":"X","createdAt":1,"updatedAt":2,"folderID":"F-1"}""");
        Assert.Equal(new Note { Id = "abc-1", Kind = NoteKind.Url, Target = "x.com", Label = "X", CreatedAt = 1, UpdatedAt = 2, FolderID = "f-1" }, note);

        var full = note! with { Text = "Hi", Pinned = true, Starred = true, Color = NoteColor.Purple, Locked = true };
        Assert.Equal(full, JsonSerializer.Deserialize<Note>(JsonSerializer.Serialize(full)));
        Assert.DoesNotContain("color", JsonSerializer.Serialize(note));  // absent fields stay out, as Swift's encoder leaves nil ones

        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<Note>("""{"id":"a","kind":"web","target":"","label":"","createdAt":1,"updatedAt":2}"""));
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<Note>("""{"id":"a","kind":"url","target":"","label":"","createdAt":1}"""));
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<Note>("""{"id":"a","kind":"url","target":"","label":"","createdAt":1,"updatedAt":2,"color":"magenta"}"""));
    }
}
