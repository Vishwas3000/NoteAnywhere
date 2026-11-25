using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace NoteAnywhere;

/// Settings ▸ Appearance (D85): Automatic follows Windows; Light or Dark sets the app's Fluent theme and the editor's
/// prefers-color-scheme, at once and in every open window.
static class Appearance
{
    public static string Current { get; private set; } = "system";
    public static event Action? Changed;

    public static void Apply(string choice)
    {
        Current = choice is "light" or "dark" ? choice : "system";
        Application.Current.ThemeMode = Current switch { "light" => ThemeMode.Light, "dark" => ThemeMode.Dark, _ => ThemeMode.System };
        Changed?.Invoke();
    }

    public static CoreWebView2PreferredColorScheme ForWebView => Current switch
    {
        "light" => CoreWebView2PreferredColorScheme.Light,
        "dark" => CoreWebView2PreferredColorScheme.Dark,
        _ => CoreWebView2PreferredColorScheme.Auto,
    };
}
