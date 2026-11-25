using System.Globalization;
using System.Text.RegularExpressions;

namespace NoteAnywhere.Core;

/// What the calendar shows, worked out as Sources/MemoryNotes/CalendarView.swift does (and Accent.swift's barColor,
/// NotesModel.swift's toggleTask and setColor), so CalendarView only draws: which days are on screen, what each day
/// holds, the week's rows of ranges, and the text edits that tick a task or colour an event.
public static partial class NoteCalendar
{
    public enum Mode { Day, Week, Month }

    /// "2026-10-30": how dated lines and snapshots name a day.
    public static string Key(DateOnly day) => day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static DateOnly WeekStart(DateOnly day, DayOfWeek first) => day.AddDays(-(((int)day.DayOfWeek - (int)first + 7) % 7));

    /// The days on screen. A month is always 6 weeks from the week of its 1st, so the grid doesn't jump in height.
    public static List<DateOnly> Days(DateOnly day, Mode mode, DayOfWeek first) => mode switch
    {
        Mode.Month => [.. Enumerable.Range(0, 42).Select(WeekStart(new DateOnly(day.Year, day.Month, 1), first).AddDays)],
        Mode.Week => [.. Enumerable.Range(0, 7).Select(WeekStart(day, first).AddDays)],
        _ => [day],
    };

    /// A month, week or day back or on (Ctrl+Left / Ctrl+Right); 31 January plus a month is 28 February, as on the Mac.
    public static DateOnly Step(DateOnly day, Mode mode, int n) => mode switch
    {
        Mode.Month => day.AddMonths(n),
        Mode.Week => day.AddDays(7 * n),
        _ => day.AddDays(n),
    };

    /// The heading: "November 2026", "Nov 22 – Nov 28, 2026" or "Wednesday, Nov 25" in the US, in the region's own order elsewhere.
    public static string Title(DateOnly day, Mode mode, CultureInfo culture)
    {
        var f = culture.DateTimeFormat;
        var monthDay = f.MonthDayPattern.Replace("MMMM", "MMM");
        if (mode == Mode.Month) return day.ToString(f.YearMonthPattern, culture);
        if (mode == Mode.Day) return day.ToString("dddd", culture) + ", " + day.ToString(monthDay, culture);
        var start = WeekStart(day, f.FirstDayOfWeek);
        var withYear = Weekday.Replace(f.LongDatePattern, "").Trim().Replace("MMMM", "MMM");
        return start.ToString(monthDay, culture) + " – " + start.AddDays(6).ToString(withYear, culture);
    }

    /// The month's header row, from the region's first day of the week.
    public static List<string> WeekdayNames(CultureInfo culture) =>
        [.. Enumerable.Range(0, 7).Select(i => culture.DateTimeFormat.AbbreviatedDayNames[((int)culture.DateTimeFormat.FirstDayOfWeek + i) % 7])];

    /// A month cell's list: up to three dated lines, then notes edited that day while there's room, and how many more.
    public static (List<DatedLine> Planned, List<Snapshot> Edited, int More) MonthCell(IReadOnlyList<DatedLine> planned, IReadOnlyList<Snapshot> edited)
    {
        List<DatedLine> lines = [.. planned.Take(3)];
        List<Snapshot> notes = [.. edited.Take(Math.Max(0, 3 - planned.Count))];
        return (lines, notes, planned.Count + edited.Count - lines.Count - notes.Count);
    }

    /// The week's ranges in rows shared by its seven columns, so a strip lines up from day to day: earliest start first,
    /// the longer of two first, and a range that starts after a row's last one ends joins that row.
    public static List<List<DatedLine>> RangeRows(IEnumerable<DatedLine> lines)
    {
        List<List<DatedLine>> rows = [];
        var ranges = lines.Where(line => line.IsRange).DistinctBy(line => (line.NoteID, line.Line, line.First))
            .OrderBy(line => line.First, StringComparer.Ordinal).ThenByDescending(line => line.Last, StringComparer.Ordinal);
        foreach (var range in ranges)
        {
            if (rows.FirstOrDefault(row => string.CompareOrdinal(row[^1].Last, range.First) < 0) is { } row) row.Add(range);
            else rows.Add([range]);
        }
        return rows;
    }

    /// One day of a range's strip: rounded where the range starts and ends; its words show on the first day and again
    /// where a week begins.
    public static (bool Starts, bool Ends, bool Titled) Strip(DatedLine range, DateOnly day, DayOfWeek first)
    {
        var starts = Key(day) == range.First;
        return (starts, Key(day) == range.Last, starts || day.DayOfWeek == first);
    }

    /// An event's colour: its own ("{red}"), else its note's label, else one picked from the line, so it stays the same
    /// between launches and two events side by side usually differ.
    public static NoteColor BarColor(this DatedLine item, NoteColor? label)
    {
        if ((item.Color ?? label) is { } color) return color;
        NoteColor[] auto = [NoteColor.Blue, NoteColor.Green, NoteColor.Purple, NoteColor.Orange, NoteColor.Cyan, NoteColor.Red];  // not pink: too close to purple when tinted
        var seed = 0;
        foreach (var scalar in (item.NoteID + "/" + item.Line.ToString(CultureInfo.InvariantCulture)).EnumerateRunes()) seed = (seed * 31 + scalar.Value) & 0xFFFFFF;
        return auto[seed % auto.Length];
    }

    /// The note's text with this task ticked, or unticked, in its line; unchanged when that line is no longer a task.
    public static string Ticked(this DatedLine item, string text)
    {
        var lines = text.Split('\n');
        if (item.Line >= lines.Length || TaskBox.Match(lines[item.Line]) is not { Success: true } box) return text;
        var mark = box.Groups[1];
        lines[item.Line] = lines[item.Line][..mark.Index] + (mark.Value == " " ? "x" : " ") + lines[item.Line][(mark.Index + 1)..];
        return string.Join('\n', lines);
    }

    /// The note's text with this event's own colour written in, or taken out with null (D67).
    public static string Recolored(this DatedLine item, string text, NoteColor? color)
    {
        var lines = text.Split('\n');
        if (item.Line >= lines.Length) return text;
        lines[item.Line] = item.Recolor(lines[item.Line], color);
        return string.Join('\n', lines);
    }

    [GeneratedRegex(@"^\s*[-*+]\s+\[([ xX])\]")]
    private static partial Regex TaskBox { get; }
    [GeneratedRegex(@"d{4}[^dMy']*")]  // "dddd, " in "dddd, MMMM d, yyyy"
    private static partial Regex Weekday { get; }
}
