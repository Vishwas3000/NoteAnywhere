using System.Globalization;
using Mode = NoteAnywhere.Core.NoteCalendar.Mode;

namespace NoteAnywhere.Core.Tests;

/// The calendar's parts of NoteTextTests.swift (event colours) and NotesModel.toggleTask, and what CalendarView.swift
/// works out for its month, week and day.
public class CalendarTests
{
    static Note N(string text) => new() { Id = "n", Kind = NoteKind.Url, Target = "", Label = "", Text = text };
    static DateOnly D(int year, int month, int day) => new(year, month, day);
    static readonly CultureInfo US = new("en-US", useUserOverride: false), UK = new("en-GB", useUserOverride: false);

    [Fact]
    public void RangesKeepTheirColour()
    {
        var note = N("""
            Dentist @2026-12-04
            Short @2026-12-04 - @2026-12-05
            Long @2026-12-03 - @2026-12-06
            """);
        var dec4 = DatedLine.ByDay(note.Dates)["2026-12-04"];
        Assert.Equal(NoteColor.Purple, dec4[0].BarColor(NoteColor.Purple));  // the note's colour label wins
        Assert.Equal(dec4[0].BarColor(null), dec4[0].BarColor(null));
        Assert.NotEqual(NoteColor.Grey, dec4[0].BarColor(null));
        Assert.NotEqual(NoteColor.Yellow, dec4[0].BarColor(null));
        Assert.Equal(NoteColor.Orange, dec4[0].BarColor(null));  // the Mac's pick for line 2 of note "n"
    }

    [Fact]
    public void EventsKeepTheirOwnColour()
    {
        var note = N("Dentist @2026-11-05{red} and gym @2026-11-06");
        var byDay = DatedLine.ByDay(note.Dates);
        Assert.Equal(NoteColor.Red, byDay["2026-11-05"][0].BarColor(NoteColor.Blue));  // its own colour beats the note's label
        Assert.Equal(NoteColor.Blue, byDay["2026-11-06"][0].BarColor(NoteColor.Blue));
    }

    [Fact]
    public void TickingATaskRewritesItsLine()
    {
        const string text = "# Launch plan\n- [ ] send build to QA @2026-10-30\n  * [X] book room 📅 2026-10-29\nParty @2026-11-01\n";
        var dates = N(text).Dates;
        var ticked = dates[0].Ticked(text);
        Assert.Equal("# Launch plan\n- [x] send build to QA @2026-10-30\n  * [X] book room 📅 2026-10-29\nParty @2026-11-01\n", ticked);
        Assert.True(N(ticked).Dates[0].Done);
        Assert.Equal(text, dates[0].Ticked(ticked));  // and back
        Assert.Equal("# Launch plan\n- [ ] send build to QA @2026-10-30\n  * [ ] book room 📅 2026-10-29\nParty @2026-11-01\n", dates[1].Ticked(text));
        Assert.Equal(text, dates[2].Ticked(text));  // not a task
        Assert.Equal("Shorter now", dates[1].Ticked("Shorter now"));  // its line is gone
    }

    [Fact]
    public void AnEventsColourIsWrittenIntoItsLine()
    {
        const string text = "Plan\nDentist @2026-11-05{red} and gym @2026-11-06";
        var dates = N(text).Dates;
        Assert.Equal("Plan\nDentist @2026-11-05{red} and gym @2026-11-06{purple}", dates[1].Recolored(text, NoteColor.Purple));
        Assert.Equal("Plan\nDentist @2026-11-05 and gym @2026-11-06", dates[0].Recolored(text, null));
        Assert.Equal("Plan", dates[0].Recolored("Plan", NoteColor.Red));
    }

    [Fact]
    public void AMonthIsSixWeeksFromTheWeekOfItsFirst()
    {
        var sundays = NoteCalendar.Days(D(2026, 11, 25), Mode.Month, DayOfWeek.Sunday);
        Assert.Equal(42, sundays.Count);
        Assert.Equal(D(2026, 11, 1), sundays[0]);  // a Sunday
        Assert.Equal(D(2026, 12, 12), sundays[^1]);
        Assert.Equal(D(2026, 10, 26), NoteCalendar.Days(D(2026, 11, 25), Mode.Month, DayOfWeek.Monday)[0]);
        Assert.Equal([.. Enumerable.Range(22, 7).Select(d => D(2026, 11, d))], NoteCalendar.Days(D(2026, 11, 25), Mode.Week, DayOfWeek.Sunday));
        Assert.Equal([D(2026, 11, 25)], NoteCalendar.Days(D(2026, 11, 25), Mode.Day, DayOfWeek.Sunday));
        Assert.Equal("2026-01-05", NoteCalendar.Key(D(2026, 1, 5)));
    }

    [Fact]
    public void StepsGoAMonthAWeekOrADay()
    {
        Assert.Equal(D(2026, 2, 28), NoteCalendar.Step(D(2026, 1, 31), Mode.Month, 1));
        Assert.Equal(D(2025, 12, 31), NoteCalendar.Step(D(2026, 1, 31), Mode.Month, -1));
        Assert.Equal(D(2026, 12, 2), NoteCalendar.Step(D(2026, 11, 25), Mode.Week, 1));
        Assert.Equal(D(2026, 11, 24), NoteCalendar.Step(D(2026, 11, 25), Mode.Day, -1));
    }

    [Fact]
    public void HeadingsReadAsOnTheMac()
    {
        Assert.Equal("November 2026", NoteCalendar.Title(D(2026, 11, 25), Mode.Month, US));
        Assert.Equal("Nov 22 – Nov 28, 2026", NoteCalendar.Title(D(2026, 11, 25), Mode.Week, US));
        Assert.Equal("Wednesday, Nov 25", NoteCalendar.Title(D(2026, 11, 25), Mode.Day, US));
        Assert.Equal("23 Nov – 29 Nov 2026", NoteCalendar.Title(D(2026, 11, 25), Mode.Week, UK));  // weeks start on Monday there
        Assert.Equal(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], NoteCalendar.WeekdayNames(US));
        Assert.Equal(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], NoteCalendar.WeekdayNames(UK));
    }

    [Fact]
    public void TheWeeksRangesShareRows()
    {
        var note = N("""
            Long @2026-11-23 - @2026-11-26
            After @2026-11-27 - @2026-11-29
            Overlap @2026-11-24 - @2026-11-25
            Same start, shorter @2026-11-23 - @2026-11-24
            Dentist @2026-11-25
            Before @2026-11-18 - @2026-11-22
            """);
        var byDay = DatedLine.ByDay(note.Dates);
        var week = NoteCalendar.Days(D(2026, 11, 25), Mode.Week, DayOfWeek.Sunday).SelectMany(d => byDay.GetValueOrDefault(NoteCalendar.Key(d)) ?? []);
        var rows = NoteCalendar.RangeRows(week);
        Assert.Equal([["Before", "Long", "After"], ["Same start, shorter"], ["Overlap"]], rows.Select(row => row.Select(range => range.Text)));
    }

    [Fact]
    public void AMonthCellListsThreeThings()
    {
        static DatedLine L(string text) => new("n", 0, "2026-11-25", text, false, false);
        static Snapshot S(string title) => new("2026-11-25", N(title));
        var (planned, edited, more) = NoteCalendar.MonthCell([L("a"), L("b")], [S("1"), S("2"), S("3")]);
        Assert.Equal((2, 1, 2), (planned.Count, edited.Count, more));
        (planned, edited, more) = NoteCalendar.MonthCell([L("a"), L("b"), L("c"), L("d")], [S("1")]);
        Assert.Equal(["a", "b", "c"], planned.Select(p => p.Text));
        Assert.Equal((0, 2), (edited.Count, more));
        (planned, edited, more) = NoteCalendar.MonthCell([], [S("1")]);
        Assert.Equal((0, 1, 0), (planned.Count, edited.Count, more));
    }

    [Fact]
    public void AStripShowsItsWordsOnItsFirstDayAndWhereAWeekBegins()
    {
        var trip = N("Trip @2026-11-27 - @2026-12-02").Dates;  // Friday to Wednesday
        Assert.Equal((true, false, true), NoteCalendar.Strip(trip[0], D(2026, 11, 27), DayOfWeek.Sunday));
        Assert.Equal((false, false, false), NoteCalendar.Strip(trip[1], D(2026, 11, 28), DayOfWeek.Sunday));
        Assert.Equal((false, false, true), NoteCalendar.Strip(trip[2], D(2026, 11, 29), DayOfWeek.Sunday));
        Assert.Equal((false, false, false), NoteCalendar.Strip(trip[2], D(2026, 11, 29), DayOfWeek.Monday));
        Assert.Equal((false, true, false), NoteCalendar.Strip(trip[5], D(2026, 12, 2), DayOfWeek.Sunday));
    }
}
