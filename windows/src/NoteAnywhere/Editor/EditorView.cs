using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using NoteAnywhere.Core;

namespace NoteAnywhere.Editor;

/// The shared Markdown editor (editor/ and app/editor.html, the same files the Mac app and the browser use) in WebView2,
/// bound to one note: every edit is saved, and an edit made elsewhere (the browser, an AI app, sync) shows at once.
/// app/editor.html talks to the Mac through webkit.messageHandlers.mn; a one-line shim points that at chrome.webview,
/// so the page is the same file (D86). Messages and replies are the Mac's (EditorView.swift).
public sealed class EditorView : ContentControl
{
    const string Host = "editor.noteanywhere";
    // One environment for every editor: WebView2 refuses a second one on the same folder with other options.
    static Task<CoreWebView2Environment>? environment;

    readonly WebView2 web = new();
    string? noteId, shown;
    bool ready, focusWhenReady;

    /// The main window's page (a wide column, formatting on highlighted text); false for the panel's cards.
    public bool Page { get; init; } = true;
    public event Action<string>? OpenNote;
    public event Action<string>? SearchTag;

    public EditorView()
    {
        Content = web;
        Loaded += async (_, _) => await StartAsync();
        NotesModel.Shared.Changed += Push;
    }

    public string? NoteId
    {
        get => noteId;
        set
        {
            if (value == noteId) return;
            noteId = value;
            shown = null;
            if (ready) _ = LoadAsync();
        }
    }

    /// Puts the cursor in the note once it has loaded (a new note: start typing right away).
    public void FocusEditor()
    {
        if (ready) { web.Focus(); _ = Call("focus"); }
        else focusWhenReady = true;
    }

    public void FindInNote() { if (ready) _ = Call("find"); }

    static Task<CoreWebView2Environment> Environment() => environment ??= CoreWebView2Environment.CreateAsync(null,
        Path.Combine(AppPaths.Data, "WebView2"),
        new CoreWebView2EnvironmentOptions { CustomSchemeRegistrations = { new(NoteStore.ImageScheme) { TreatAsSecure = true, HasAuthorityComponent = false } } });

    async Task StartAsync()
    {
        if (web.CoreWebView2 != null) return;
        await web.EnsureCoreWebView2Async(await Environment());
        var core = web.CoreWebView2!;
        core.SetVirtualHostNameToFolderMapping(Host, Path.Combine(AppContext.BaseDirectory, "editor"), CoreWebView2HostResourceAccessKind.Allow);
        await core.AddScriptToExecuteOnDocumentCreatedAsync(
            "window.webkit = { messageHandlers: { mn: { postMessage: (m) => window.chrome.webview.postMessage(m) } } };");
        core.Settings.IsStatusBarEnabled = false;
        core.Profile.PreferredColorScheme = Appearance.ForWebView;
        Appearance.Changed += () => core.Profile.PreferredColorScheme = Appearance.ForWebView;
        // Note images (noteimage:<id>) come from the store, like the Mac's ImageScheme.
        core.AddWebResourceRequestedFilter(NoteStore.ImageScheme + ":*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) =>
        {
            var id = e.Request.Uri[(NoteStore.ImageScheme.Length + 1)..];
            e.Response = NoteStore.Image(id) is { } image
                ? core.Environment.CreateWebResourceResponse(new MemoryStream(image.Data), 200, "OK", $"Content-Type: {image.Type}")
                : core.Environment.CreateWebResourceResponse(null, 404, "Not Found", "");
        };
        // Links open in the default browser, never inside the editor (the editor opens web links with window.open).
        core.NewWindowRequested += (_, e) => { e.Handled = true; OpenOutside(e.Uri); };
        core.NavigationStarting += (_, e) =>
        {
            if (e.Uri.StartsWith($"https://{Host}/", StringComparison.Ordinal)) return;
            e.Cancel = true;
            OpenOutside(e.Uri);
        };
        core.WebMessageReceived += OnMessage;
        core.Navigate($"https://{Host}/editor.html");
    }

    static void OpenOutside(string uri)
    {
        if (Uri.TryCreate(uri, UriKind.Absolute, out var u) && u.Scheme is "http" or "https" or "mailto")
            Process.Start(new ProcessStartInfo(u.AbsoluteUri) { UseShellExecute = true });
    }

    Note? Current => noteId is null ? null : NotesModel.Shared.Find(noteId);

    Task LoadAsync()
    {
        shown = Current?.Text ?? "";
        var options = new Dictionary<string, object>
        {
            ["toolbar"] = Page ? "selection" : false, ["fontSize"] = Page ? 15 : 13, ["titleLine"] = true, ["page"] = Page,
            ["datePattern"] = Settings.Load().DateFormat is { Length: > 0 } f ? f : DateStyle.Region, ["pages"] = true,
        };
        return Call("load", shown, options);
    }

    /// An edit made elsewhere: the editor shows it, unless it's what the editor already holds.
    void Push()
    {
        if (!ready || Current is not { } note || note.Text == shown) return;
        shown = note.Text;
        _ = Call("set", note.Text);
    }

    Task Call(string function, params object?[] args) =>
        web.CoreWebView2?.ExecuteScriptAsync($"MNHost.{function}(...{JsonSerializer.Serialize(args)})") ?? Task.CompletedTask;

    Task Reply(int id, object? value, string? error = null) => Call("reply", id, value, error);

    async void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        using var doc = JsonDocument.Parse(e.WebMessageAsJson);
        var msg = doc.RootElement;
        string? Text(string name) => msg.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        var id = msg.TryGetProperty("id", out var idValue) && idValue.ValueKind == JsonValueKind.Number ? idValue.GetInt32() : 0;
        var notes = NotesModel.Shared;
        try
        {
            switch (Text("type"))
            {
                case "ready":
                    ready = true;
                    await LoadAsync();
                    if (focusWhenReady || shown?.Length == 0) { focusWhenReady = false; FocusEditor(); }
                    break;
                case "change":
                    shown = Text("markdown") ?? "";
                    if (noteId != null) notes.SaveText(noteId, shown);
                    break;
                case "height":
                    // A card sized to its note (the panel), within the Mac's 44–320 points.
                    if (!Page && msg.TryGetProperty("value", out var h) && h.ValueKind == JsonValueKind.Number) Height = Math.Clamp(h.GetDouble(), 44, 320);
                    break;
                case "openNote":
                    if (Text("id") is { } open) OpenNote?.Invoke(open.ToLowerInvariant());
                    break;
                case "tag":
                    if (Text("tag") is { } tag) SearchTag?.Invoke(tag);
                    break;
                case "findTags":
                    await Reply(id, NoteActions.TagCounts(notes.Notes).Select(t => new { tag = t.Tag, count = t.Count }).ToList());
                    break;
                case "findNotes":
                    var query = (Text("query") ?? "").Trim();
                    await Reply(id, notes.Notes.Where(n => n.Id != noteId && !n.Locked)
                        .Where(n => query.Length == 0 || n.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) || n.Preview.Contains(query, StringComparison.CurrentCultureIgnoreCase))
                        .OrderByDescending(n => n.UpdatedAt).Take(8).Select(n => new { id = n.Id, title = n.Title, preview = n.Preview }).ToList());
                    break;
                case "notePreview":
                    if (notes.Find((Text("note") ?? "").ToLowerInvariant()) is { } linked)
                        await Reply(id, new { title = linked.Title, preview = linked.Locked ? "Unlock it to read it." : linked.Preview.Length > 320 ? linked.Preview[..320] : linked.Preview });
                    else await Reply(id, null, "This note was deleted.");
                    break;
                case "addPage":
                    var parent = Current;
                    await Reply(id, notes.Add(NoteKind.Url, "", "", parent?.FolderID, NoteActions.PageText(Text("text") ?? "", parent)).Id);
                    break;
                case "addImage":
                    var data = Text("data") is { } b64 ? Convert.FromBase64String(b64) : null;
                    await (data is null ? Reply(id, null, "The image data was unreadable.")
                        : Reply(id, NoteStore.ImageScheme + ":" + NoteStore.SaveImage(data, Text("mime") ?? "")));
                    break;
                case "ai":
                    await Reply(id, null, "The writing model isn't on this PC yet: it arrives in a coming update.");
                    break;
                case "linkPreview":
                    await Reply(id, null, "Link previews aren't on Windows yet.");
                    break;
            }
        }
        catch (Exception error) when (id != 0)
        {
            await Reply(id, null, error.Message);
        }
    }
}
