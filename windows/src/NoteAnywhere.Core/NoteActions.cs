namespace NoteAnywhere.Core;

/// What the notes window does to notes, as the Mac's NotesModel: shared so the window, the panel and tests agree.
public static class NoteActions
{
    public static double Now => DateTimeOffset.Now.ToUnixTimeMilliseconds();

    /// "Why does sync lag?\n\n↖ [Sync notes](note://ID)\n\n": the highlight on one line as the title, then the way back.
    public static string PageText(string title, Note? parent)
    {
        var line = string.Join(" ", title.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries));
        var back = parent is null ? "" : $"\n\n↖ [{parent.Title.Replace("]", "\\]")}](note://{parent.Id})";
        return line + back + "\n\n";
    }

    /// "Slack › Acme › Alex Rivera (DM)" for app notes; a website note's address.
    public static string Place(Note note) => note.Kind == NoteKind.App
        ? string.Join(" › ", [note.Label, .. note.Target.Split('/', StringSplitOptions.RemoveEmptyEntries).Skip(1)])
        : note.Target;

    /// Every #tag in use with its number of notes, most used first, then A to Z (the sidebar and the "#" menu).
    public static List<(string Tag, int Count)> TagCounts(IEnumerable<Note> notes) =>
        notes.SelectMany(n => n.Tags).GroupBy(t => t).Select(g => (Tag: g.Key, Count: g.Count()))
            .OrderByDescending(t => t.Count).ThenBy(t => t.Tag, StringComparer.Ordinal).ToList();

    /// Words search until meaning-based search arrives: a "#tag" query lists that tag's notes; otherwise every word must
    /// be in the title, preview or text. Newest first; locked notes are matched by nothing but their title.
    public static List<Note> Search(IEnumerable<Note> notes, string query)
    {
        query = query.Trim();
        if (query.Length == 0) return [];
        if (query.StartsWith('#') && Note.TagName(query) is { } tag)
            return notes.Where(n => n.HasTag(tag)).OrderByDescending(n => n.UpdatedAt).ToList();
        var words = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return notes.Where(n => words.All(w => (n.Locked ? n.Title : n.Title + "\n" + n.Text).Contains(w, StringComparison.CurrentCultureIgnoreCase)))
            .OrderByDescending(n => n.UpdatedAt).ToList();
    }
}
