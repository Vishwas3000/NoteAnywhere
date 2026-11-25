using System.IO;
using System.Text.Json;
using Microsoft.Win32;
using NoteAnywhere.Core;

namespace NoteAnywhere.Platform;

/// Registers this program as the native messaging host of the Chromium browsers and Firefox, at every launch, as the
/// Mac's BrowserBridge does: on Windows a browser finds a host through a registry key whose default value is the path of
/// its manifest (per-user keys, so no administrator is needed). A manifest is rewritten only when it differs.
static class BrowserRegistration
{
    public const string HostName = "com.memorynotes.host";
    // The same ids as the Mac (BrowserBridge.swift): the unpacked extension, the Web Store's, Firefox's add-on.
    const string DevExtensionID = "fmjimldgmehkakonbffiaacmpijhajop", StoreExtensionID = "fngldbimlphnokkkkodneojgbdnofjha";
    const string FirefoxAddonID = "noteanywhere@noteanywhere.app";

    static readonly string[] Chromium =
    [
        @"Software\Google\Chrome", @"Software\Microsoft\Edge", @"Software\Chromium", @"Software\BraveSoftware\Brave-Browser",
        @"Software\Vivaldi",
    ];

    public static void RegisterThisApp()
    {
        var exe = Environment.ProcessPath;
        if (exe is null) return;
        Directory.CreateDirectory(AppPaths.Data);
        var chrome = WriteIfChanged(Path.Combine(AppPaths.Data, HostName + ".json"), Manifest(exe, firefox: false));
        var firefox = WriteIfChanged(Path.Combine(AppPaths.Data, HostName + ".firefox.json"), Manifest(exe, firefox: true));
        foreach (var browser in Chromium) SetDefault($@"{browser}\NativeMessagingHosts\{HostName}", chrome);
        SetDefault($@"Software\Mozilla\NativeMessagingHosts\{HostName}", firefox);
    }

    /// Chrome's manifest lists extension origins; Firefox's lists add-on ids.
    static string Manifest(string exe, bool firefox) => JsonSerializer.Serialize(new Dictionary<string, object>
    {
        ["name"] = HostName,
        ["description"] = "NoteAnywhere",
        ["path"] = exe,
        ["type"] = "stdio",
        [firefox ? "allowed_extensions" : "allowed_origins"] = firefox
            ? new[] { FirefoxAddonID }
            : new[] { $"chrome-extension://{DevExtensionID}/", $"chrome-extension://{StoreExtensionID}/" },
    }, new JsonSerializerOptions { WriteIndented = true });

    static string WriteIfChanged(string path, string text)
    {
        if (!File.Exists(path) || File.ReadAllText(path) != text) File.WriteAllText(path, text);
        return path;
    }

    static void SetDefault(string key, string value)
    {
        using var k = Registry.CurrentUser.CreateSubKey(key);
        if (k.GetValue("") as string != value) k.SetValue("", value);
    }
}
