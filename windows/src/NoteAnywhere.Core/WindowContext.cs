using System.Text.RegularExpressions;

namespace NoteAnywhere.Core;

/// Turns a front window's title into a context path inside its app, broad to narrow, as the Mac does
/// (WindowContext.swift): "Alex Rivera (DM) - Acme - 8 new items - Slack" → ["Acme", "Alex Rivera (DM)"].
/// App notes target "app.id/Acme/Alex Rivera (DM)", so like web pages a parent context sees its children's notes.
public static partial class WindowContext
{
    public static List<string> Path(string? title, string appName)
    {
        title = title?.Trim();
        if (string.IsNullOrEmpty(title)) return [];
        var parts = Separator().Split(title).Where(p => p.Length > 0).Select(Clean).ToList();  // Swift's split drops empties
        var app = Clean(appName).ToLowerInvariant();
        // The app's own name ("Slack", "Brave" for "Brave Browser", "Visual Studio Code" for "Code") marks which end of
        // the title is the broad one.
        bool IsApp(string part)
        {
            part = part.ToLowerInvariant();
            return part.Length > 0 && (app.StartsWith(part, StringComparison.Ordinal) || part.StartsWith(app, StringComparison.Ordinal)
                                       || part.EndsWith(" " + app, StringComparison.Ordinal));
        }
        var broadFirst = true;
        if (parts.Count == 1 && IsApp(parts[0])) return [];  // "WhatsApp": the title names only the app
        if (parts.Count > 1 && IsApp(parts[^1]))
        {
            parts.RemoveAt(parts.Count - 1);
            broadFirst = false;  // "narrow - broad - App"
        }
        else if (parts.Count > 1 && IsApp(parts[0]))
        {
            parts.RemoveAt(0);
        }
        parts.RemoveAll(p => p.Length == 0 || Counter().IsMatch(p));
        if (!broadFirst) parts.Reverse();
        return parts.Select(p => p.Replace("/", "∕")).ToList();  // "/" separates levels in the target
    }

    /// `conversation` is the open chat read from inside the window, for apps whose title never names it.
    public static string Target(string appId, string appName, string? title, string? conversation = null)
    {
        var path = Path(title, appName);
        if (path.Count == 0 && conversation is not null && Clean(conversation) is { Length: > 0 } chat) path = [chat.Replace("/", "∕")];
        return string.Join("/", [appId, .. path]);
    }

    /// Drops what changes without the place changing: unsaved dots, unread counts like "(3) Inbox" / "Inbox (3)", and
    /// invisible marks: bidi marks (WhatsApp) and the zero-width space Edge puts in "Microsoft​ Edge".
    static string Clean(string part)
    {
        var visible = new string(part.Where(c => !Invisible.Contains(c)).ToArray());
        visible = Leading().Replace(visible, "");  // unsaved dots, spinners ("✳ Claude Code"), bullets
        visible = CountFront().Replace(visible, "");
        visible = CountBack().Replace(visible, "");
        return visible.Trim();
    }

    const string Invisible = "‎‏‪‫‬‭‮⁦⁧⁨⁩​";
    [GeneratedRegex(@"\s[-—–|]\s")] private static partial Regex Separator();
    [GeneratedRegex(@"^(\d+\s+(new\s+items?|unread.*|notifications?|messages?)|edited)$", RegexOptions.IgnoreCase)] private static partial Regex Counter();
    [GeneratedRegex(@"^[^\p{L}\p{N}(\[#@~]+")] private static partial Regex Leading();
    [GeneratedRegex(@"^\(\d+\)\s*")] private static partial Regex CountFront();
    [GeneratedRegex(@"\s*\(\d+\)$")] private static partial Regex CountBack();
}
