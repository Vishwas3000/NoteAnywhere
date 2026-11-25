using System.Globalization;
using NoteAnywhere.Core;

namespace NoteAnywhere.Core.Tests;

/// The Mac's NoteDatesTests.swift: the sidebar's sections, row dates and source lines.
public class NoteDatesSidebarTests
{
    static readonly CultureInfo US = CultureInfo.GetCultureInfo("en-US");
    static DateTimeOffset Day(int y, int m, int d, int h = 12) => new(y, m, d, h, h == 14 ? 14 : 5, 0, TimeSpan.Zero);
    static Note Edited(DateTimeOffset date) => new() { Kind = NoteKind.App, Target = "x", Label = "X", UpdatedAt = date.ToUnixTimeMilliseconds() };
    static readonly DateTimeOffset Now = Day(2026, 10, 28, 14);  // a Wednesday

    [Fact]
    public void SectionsLikeAppleNotes()
    {
        DateTimeOffset[] dates =
        [
            Day(2025, 12, 1), Day(2026, 9, 27), Day(2026, 9, 28), Day(2026, 10, 20), Day(2026, 10, 21),
            Day(2026, 10, 22), Day(2026, 10, 27, 0), Day(2026, 10, 28, 0), Day(2026, 10, 29),  // the last one: a clock change
        ];
        var sections = NoteDates.Sections(dates.Select(Edited), Now, TimeZoneInfo.Utc, US);
        Assert.Equal(["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "September 2026", "December 2025"], sections.Select(s => s.Title));
        Assert.Equal([2, 1, 2, 2, 1, 1], sections.Select(s => s.Notes.Count));
        Assert.Equal(Day(2026, 10, 29), sections[0].Notes[0].Edited);  // newest first
    }

    [Fact]
    public void ShortDates()
    {
        Assert.StartsWith("9:05", NoteDates.Short(Day(2026, 10, 28, 9), Now, TimeZoneInfo.Utc, US));
        Assert.Equal("Sunday", NoteDates.Short(Day(2026, 10, 25), Now, TimeZoneInfo.Utc, US));
        Assert.Equal("10/21/26", NoteDates.Short(Day(2026, 10, 21), Now, TimeZoneInfo.Utc, US));
    }

    [Fact]
    public void ShortSources()
    {
        Assert.Equal("Slack · Alex Rivera (DM)", new Note { Kind = NoteKind.App, Target = "com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)", Label = "Slack" }.ShortSource());
        Assert.Equal("Xcode", new Note { Kind = NoteKind.App, Target = "com.apple.dt.Xcode", Label = "Xcode" }.ShortSource());
        Assert.Equal("chatgpt.com", new Note { Kind = NoteKind.Url, Target = "chatgpt.com/c/123", Label = "Whisper STT Explained" }.ShortSource());
        var alone = new Note { Kind = NoteKind.Url, Target = "", Label = "" };
        Assert.True(alone.ShortSource() == "" && !alone.HasSource);
    }
}
