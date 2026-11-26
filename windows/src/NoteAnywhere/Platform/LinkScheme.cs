using Microsoft.Win32;

namespace NoteAnywhere.Platform;

/// memorynotes:// links open this program, as on the Mac and the phones: a sync sign-in email's link and Google's return
/// come back this way. Registered for this user at every launch, so it needs no administrator and always names the
/// program that last ran.
static class LinkScheme
{
    public const string Prefix = "memorynotes:";

    public static void RegisterThisApp()
    {
        if (Environment.ProcessPath is not { } exe) return;
        using var scheme = Registry.CurrentUser.CreateSubKey(@"Software\Classes\memorynotes");
        scheme.SetValue("", "URL:NoteAnywhere");
        scheme.SetValue("URL Protocol", "");
        using var command = scheme.CreateSubKey(@"shell\open\command");
        command.SetValue("", $"\"{exe}\" \"%1\"");
    }
}
