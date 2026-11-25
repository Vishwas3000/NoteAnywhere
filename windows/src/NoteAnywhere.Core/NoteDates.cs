using System.Globalization;

namespace NoteAnywhere.Core;

/// Apple Notes' date wording for the sidebar, as the Mac's NoteDates: `now`, the time zone and the culture are
/// parameters so tests can pin them.
public static class NoteDates
{
    public sealed record Section(string Title, List<Note> Notes);

    /// Newest edit first: Today, Yesterday, Previous 7 Days, Previous 30 Days, then "October 2026".
    public static List<Section> Sections(IEnumerable<Note> notes, DateTimeOffset now, TimeZoneInfo zone, CultureInfo culture)
    {
        var sections = new List<Section>();
        foreach (var note in notes.OrderByDescending(n => n.UpdatedAt))
        {
            var title = Days(note.Edited, now, zone) switch
            {
                <= 0 => "Today",
                1 => "Yesterday",
                <= 7 => "Previous 7 Days",
                <= 30 => "Previous 30 Days",
                _ => TimeZoneInfo.ConvertTime(note.Edited, zone).ToString("MMMM yyyy", culture),
            };
            if (sections.Count > 0 && sections[^1].Title == title) sections[^1].Notes.Add(note);
            else sections.Add(new Section(title, [note]));
        }
        return sections;
    }

    public static List<Section> Sections(IEnumerable<Note> notes) =>
        Sections(notes, DateTimeOffset.Now, TimeZoneInfo.Local, CultureInfo.CurrentCulture);

    /// A row's date: the time today, the weekday within the past week, otherwise a short date with a 2-digit year.
    public static string Short(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo zone, CultureInfo culture)
    {
        var local = TimeZoneInfo.ConvertTime(date, zone);
        return Days(date, now, zone) switch
        {
            <= 0 => local.ToString(culture.DateTimeFormat.ShortTimePattern, culture),
            <= 6 => local.ToString("dddd", culture),
            _ => local.ToString(culture.DateTimeFormat.ShortDatePattern.Replace("yyyy", "yy"), culture),
        };
    }

    public static string Short(DateTimeOffset date) => Short(date, DateTimeOffset.Now, TimeZoneInfo.Local, CultureInfo.CurrentCulture);

    /// "Slack · Alex Rivera (DM)" or "chatgpt.com": the app with its narrowest place, or the site's host.
    public static string ShortSource(this Note note)
    {
        if (note.Kind == NoteKind.Url) return new string(note.Target.TakeWhile(c => c != '/').ToArray());
        var parts = note.Target.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 1 ? $"{note.Label} · {parts[^1]}" : note.Label;
    }

    /// Calendar days between the two dates; edits from the future (clock changes) count as today.
    static int Days(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo zone) =>
        (TimeZoneInfo.ConvertTime(now, zone).Date - TimeZoneInfo.ConvertTime(date, zone).Date).Days;
}
