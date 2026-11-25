using System.Globalization;

namespace NoteAnywhere.Core.Tests;

/// The date tests of NoteTextTests.swift and NoteDatesTests.swift, and more: where the Mac has no test, the values are what its Note.swift returned.
public class NoteDatesTests
{
    static Note N(string text) => new() { Id = "n", Kind = NoteKind.Url, Target = "", Label = "", Text = text };

    static T InCulture<T>(string name, Func<T> body)
    {
        var culture = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = new CultureInfo(name, useUserOverride: false);
        try { return body(); }
        finally { CultureInfo.CurrentCulture = culture; }
    }

    [Fact]
    public void DatedLines()
    {
        var note = N("""
            # Launch plan
            - [ ] send build to QA @2026-10-30
            - [x] book room 📅 2026-10-29
            Party on @2026-11-01 and @2026-11-01, not `@2026-11-02`, not me@2026-11-03 or @2026-02-30
            ```
            @2026-11-04
            ```
            """);
        Assert.Equal(["2026-10-30", "2026-10-29", "2026-11-01"], note.Dates.Select(d => d.Day));
        Assert.Equal(["send build to QA", "book room", "Party on and , not , not me or"], note.Dates.Select(d => d.Text));
        Assert.Equal([true, true, false], note.Dates.Select(d => d.IsTask));
        Assert.Equal([false, true, false], note.Dates.Select(d => d.Done));
        Assert.Equal([1, 2, 3], note.Dates.Select(d => d.Line));
    }

    [Fact]
    public void DatedRanges()
    {
        var note = N("""
            Rohin Wedding @2026-12-03 - @2026-12-06
            Trip @2026-12-31 to @2027-01-01, call @2026-12-20
            Backwards @2026-12-10 – @2026-12-09
            Same day @2026-12-15 - @2026-12-15
            """);
        var wedding = note.Dates.Where(d => d.Line == 0).ToList();
        Assert.Equal(["2026-12-03", "2026-12-04", "2026-12-05", "2026-12-06"], wedding.Select(d => d.Day));
        Assert.All(wedding, d => Assert.True(d.IsRange && d.First == "2026-12-03" && d.Last == "2026-12-06" && d.Text == "Rohin Wedding"));
        var trip = note.Dates.Where(d => d.Line == 1).ToList();
        Assert.Equal(["2026-12-20", "2026-12-31", "2027-01-01"], trip.Select(d => d.Day));  // across a year, and the single date too
        Assert.Equal([false, true, true], trip.Select(d => d.IsRange));
        Assert.Equal("Trip , call", trip[0].Text);
        Assert.Equal(["2026-12-09", "2026-12-10"], note.Dates.Where(d => d.Line == 2).Select(d => d.Day));
        Assert.Equal([false], note.Dates.Where(d => d.Line == 3).Select(d => d.IsRange));  // a one-day "range" is just a date
        Assert.Equal(366, DatedLine.Days("2026-01-01", "2099-01-01").Count);
        Assert.Equal(["9999-12-30", "9999-12-31"], DatedLine.Days("9999-12-30", "9999-12-31"));  // the last day there is
        Assert.Equal(["2026-01-01", "2026-01-02"], DatedLine.Days("2026-1-1", "2026-01-02"));
    }

    [Fact]
    public void RangesKeepTheirRow()
    {
        var note = N("""
            Dentist @2026-12-04
            Short @2026-12-04 - @2026-12-05
            Long @2026-12-03 - @2026-12-06
            """);
        Assert.Equal(["Long", "Short", "Dentist"], DatedLine.ByDay(note.Dates)["2026-12-04"].Select(d => d.Text));  // earliest start first, then single days
    }

    [Fact]
    public void EventsKeepTheirOwnColour()
    {
        var note = N("""
            Dentist @2026-11-05{red} and gym @2026-11-06
            Goa @2026-11-15{green} – @2026-11-12, odd @2026-11-20{bogus}
            """);
        var byDay = note.Dates.GroupBy(d => d.Day).ToDictionary(g => g.Key, g => g.ToList());
        Assert.Equal(NoteColor.Red, byDay["2026-11-05"][0].Color);
        Assert.Null(byDay["2026-11-06"][0].Color);
        Assert.All(note.Dates.Where(d => d.IsRange), d => Assert.True(d.Color == NoteColor.Green && d.First == "2026-11-12"));
        Assert.Null(byDay["2026-11-20"][0].Color);
        Assert.Equal("Dentist and gym", note.Dates[0].Text);  // the colour isn't part of the event's words
        Assert.Equal("Dentist " + DateStyle.Format("2026-11-05"), Note.Plain("Dentist @2026-11-05{red}"));

        var lines = note.Text.Split('\n');
        DatedLine gym = byDay["2026-11-06"][0], dentist = byDay["2026-11-05"][0], goa = byDay["2026-11-13"][0];
        Assert.Equal("Dentist @2026-11-05{red} and gym @2026-11-06{purple}", gym.Recolor(lines[0], NoteColor.Purple));
        Assert.Equal("Dentist @2026-11-05 and gym @2026-11-06", dentist.Recolor(lines[0], null));
        Assert.Equal("Dentist @2026-11-05{cyan} and gym @2026-11-06", dentist.Recolor(lines[0], NoteColor.Cyan));
        // A range takes one colour, on the date written first, whichever end that is.
        var orange = goa.Recolor(lines[1], NoteColor.Orange);
        Assert.Equal("Goa @2026-11-15{orange} – @2026-11-12, odd @2026-11-20{bogus}", orange);
        Assert.All(N(orange).Dates.Where(d => d.IsRange), d => Assert.Equal(NoteColor.Orange, d.Color));
        Assert.Equal("Goa @2026-11-15 – @2026-11-12", goa.Recolor("Goa @2026-11-15{green} – @2026-11-12{red}", null));
    }

    [Fact]
    public void DatesInNotesShowInTheChosenFormat()
    {
        Assert.Equal("30/10/2026", DateStyle.Format("2026-10-30", "dd/MM/yyyy"));
        Assert.Equal("10/30/2026", DateStyle.Format("2026-10-30", "MM/dd/yyyy"));
        Assert.Equal("30.10.2026", DateStyle.Format("2026-10-30", "dd.MM.y"));
        Assert.Equal("Fri, 30 Oct 2026", DateStyle.Format("2026-10-30", "EEE, d MMM yyyy"));
        Assert.Equal("30 October 2026", DateStyle.Format("2026-10-30", "d MMMM yyyy"));
        Assert.Equal("Friday, 30 October", DateStyle.Format("2026-10-30", "EEEE, d MMMM", thisYear: 2026));
        Assert.Equal("Tuesday, 5 January 2027", DateStyle.Format("2027-01-05", "EEEE, d MMMM", thisYear: 2026));
        Assert.Equal("Mon 30 Feb 2026", DateStyle.Format("2026-02-30", "EEE d MMM yyyy"));  // weekday of 2 March, as the Mac's calendar rolls over
        Assert.Equal("5 Jan 99", DateStyle.Format("0099-01-05", "d MMM", thisYear: 2026));
        Assert.Equal("2026-13-01", DateStyle.Format("2026-13-01", "dd/MM/yyyy"));

        // The Mac reads the chosen pattern from Settings; Windows has the region's, here en-GB's.
        var note = N("Printer\nCall them @2026-10-30, not @2026-02-30");
        Assert.Equal("Call them 30/10/2026, not @2026-02-30", InCulture("en-GB", () => note.Preview));
        Assert.Equal(["2026-10-30"], note.Dates.Select(d => d.Day));  // the text itself keeps the ISO day
    }

    [Fact]
    public void TheRegionsPatternHasDayMonthAndAFourDigitYear()
    {
        Assert.Equal("MM/dd/yyyy", InCulture("en-US", () => DateStyle.Region));
        Assert.Equal("dd/MM/yyyy", InCulture("en-GB", () => DateStyle.Region));
        Assert.Equal("dd.MM.yyyy", InCulture("de-DE", () => DateStyle.Region));
    }

    [Theory]
    [InlineData("2026-10-30", true)]
    [InlineData("2024-02-29", true)]
    [InlineData("2026-02-29", false)]
    [InlineData("2026-02-30", false)]
    [InlineData("2026-11-31", false)]
    [InlineData("2026-13-01", false)]
    [InlineData("2026-00-10", false)]
    [InlineData("2026-01-00", false)]
    [InlineData("2026-1-05", false)]
    [InlineData(" 2026-01-05", false)]
    [InlineData("+2026-01-05", false)]
    [InlineData("2026-01-05T00:00", false)]
    [InlineData("٢٠٢٦-١٠-٣٠", false)]
    [InlineData("0000-01-01", false)]
    [InlineData("9999-12-31", true)]
    [InlineData("", false)]
    public void OnlyRealDaysAreDays(string day, bool isDay) => Assert.Equal(isDay, DatedLine.IsDay(day));

    [Fact]
    public void WhereADateEndsAndATaskBegins()
    {
        Assert.Equal(["1 Paren ()", "2 Bracket []", "8 Colour x"], N("""
            Arabic @٢٠٢٦-١٠-٣٠
            Paren (@2026-10-30)
            Bracket [@2026-10-30]
            Glued x@2026-10-30
            After @2026-10-30x
            Dash @2026-10-30-
            Underscore @2026-10-30_
            Accent @2026-10-30é
            Colour @2026-10-30{red}x
            """).Dates.Select(d => $"{d.Line} {d.Text}"));
        Assert.Equal(["0 one", "2 tab", "3 tight"], N("📅 2026-10-30 one\n📅  2026-10-30 two spaces\n📅\t2026-10-30 tab\n📅2026-10-30 tight")
            .Dates.Select(d => $"{d.Line} {d.Text}"));
        Assert.Equal(["done True True", "[ ]no space False False", "indented True True", "plus True False", "[ ] numbered False False"], N("""
            * [x] done @2026-10-30
            - [ ]no space @2026-10-30
              - [X] indented @2026-10-30
            + [ ] plus @2026-10-30
            1. [ ] numbered @2026-10-30
            """).Dates.Select(d => $"{d.Text} {d.IsTask} {d.Done}"));
        Assert.Equal([NoteColor.Green, NoteColor.Red], N("Twice @2026-10-30 and @2026-10-30{green} and @2026-10-30{red}\nFirst colour @2026-10-31{red} then @2026-10-31")
            .Dates.Select(d => d.Color));  // a date twice on a line is one event; the first colour given wins
    }
}
