using NoteAnywhere.Core;

namespace NoteAnywhere.Core.Tests;

/// The Mac's WindowContextTests.swift, case for case, plus what only Windows titles do.
public class WindowContextTests
{
    [Theory]
    // Slack: narrow first, app last; unread counts dropped.
    [InlineData("Alex Rivera (DM) - Acme - 8 new items - Slack", "Slack", new[] { "Acme", "Alex Rivera (DM)" })]
    [InlineData("general (Channel) - Acme - Slack", "Slack", new[] { "Acme", "general (Channel)" })]
    [InlineData("general (Channel) - Acme - 1 new item - Slack", "Slack", new[] { "Acme", "general (Channel)" })]
    // VS Code: unsaved dot dropped, em-dash separators.
    [InlineData("● Note.swift — memoryNotes — Visual Studio Code", "Code", new[] { "memoryNotes", "Note.swift" })]
    // Browser whose app name is longer than its title suffix.
    [InlineData("ChatGPT - Brave", "Brave Browser", new[] { "ChatGPT" })]
    // Broad first, no app name.
    [InlineData("memoryNotes — Note.swift", "Xcode", new[] { "memoryNotes", "Note.swift" })]
    // Counts in front or behind.
    [InlineData("(3) Inbox - Mail", "Mail", new[] { "Inbox" })]
    [InlineData("Inbox (12)", "Mail", new[] { "Inbox" })]
    // A "/" inside a name must not create a level.
    [InlineData("a/b.txt", "TextEdit", new[] { "a∕b.txt" })]
    // Window titled just like the app, or nothing.
    [InlineData("Slack", "Slack", new string[0])]
    // Animated titles (a terminal spinner) stay one place.
    [InlineData("✳ Claude Code", "Terminal", new[] { "Claude Code" })]
    [InlineData("⠋ Claude Code", "Terminal", new[] { "Claude Code" })]
    [InlineData("", "Slack", new string[0])]
    // Windows: Edge writes its name with a zero-width space, "Microsoft​ Edge".
    [InlineData("GitHub - Work - Microsoft​ Edge", "Microsoft Edge", new[] { "Work", "GitHub" })]
    [InlineData("Notes.txt - Notepad", "Notepad", new[] { "Notes.txt" })]
    public void WindowTitlePath(string title, string app, string[] expected) =>
        Assert.Equal(expected, WindowContext.Path(title, app));

    [Fact]
    public void Target()
    {
        Assert.Equal("com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)",
            WindowContext.Target("com.tinyspeck.slackmacgap", "Slack", "Alex Rivera (DM) - Acme - Slack"));
        Assert.Equal("win.explorer", WindowContext.Target("win.explorer", "File Explorer", null));
    }

    [Fact]
    public void ConversationFromInsideTheWindow()
    {
        // WhatsApp's title is only "‎WhatsApp"; the chat comes from its header element.
        Assert.Empty(WindowContext.Path("‎WhatsApp", "WhatsApp"));
        Assert.Equal("net.whatsapp.WhatsApp/Project ∕ Team",
            WindowContext.Target("net.whatsapp.WhatsApp", "WhatsApp", "‎WhatsApp", "‎Project / Team"));
        Assert.Equal("net.whatsapp.WhatsApp/Book Club",
            WindowContext.Target("net.whatsapp.WhatsApp", "‎WhatsApp", "‎WhatsApp", "Book Club"));
        // A title that already names the place wins over the header.
        Assert.Equal("x/Acme/general", WindowContext.Target("x", "Slack", "general - Acme - Slack", "other"));
    }

    [Theory]
    [InlineData("slack", "com.tinyspeck.slackmacgap")]
    [InlineData("Code", "com.microsoft.VSCode")]
    [InlineData("msedge", "com.microsoft.edgemac")]
    [InlineData("Notepad", "win.notepad")]
    public void AppIds(string exe, string id) => Assert.Equal(id, WindowsApps.Id(exe));
}
