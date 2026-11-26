using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using NoteAnywhere.Core;
using NoteAnywhere.Core.Crypto;
using NoteAnywhere.Platform;

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

    // Transparent, as the page is, so the window's theme shows through: WebView2's own white made dark mode's text unreadable.
    readonly WebView2 web = new() { DefaultBackgroundColor = System.Drawing.Color.Transparent };
    // A locked note's text is its sealed envelope (mnlock:v1:…): the editor never shows it, and never writes over it
    // (typing at its end would still pass the store's guard and break it). Unlocked (LockSession), the editor shows
    // what it opens to, and each edit is sealed again before it's saved, as on the Mac.
    readonly PasswordBox password = new() { MinWidth = 160 };
    readonly TextBlock hint = new() { Opacity = 0.6, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
    readonly TextBlock problem = new() { Opacity = 0.8, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    readonly StackPanel lockPanel;
    string? noteId, shown;
    bool ready, focusWhenReady, shut;

    /// The main window's page (a wide column, formatting on highlighted text); false for the panel's cards.
    public bool Page { get; init; } = true;
    public event Action<string>? OpenNote;
    public event Action<string>? SearchTag;

    public EditorView()
    {
        var unlock = new Button { Content = "Unlock", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 2, 12, 2) };
        unlock.Click += (_, _) => Unlock();
        password.KeyDown += (_, e) => { if (e.Key == Key.Enter) Unlock(); };
        System.Windows.Automation.AutomationProperties.SetName(password, "Notes password");
        lockPanel = new StackPanel
        {
            Margin = new Thickness(16), Visibility = Visibility.Collapsed,
            Children =
            {
                new TextBlock { Text = "This note is locked.", Opacity = 0.8, Margin = new Thickness(0, 0, 0, 8) },
                hint,
                new DockPanel { Children = { unlock, password }, LastChildFill = true },
                problem,
            },
        };
        DockPanel.SetDock(unlock, Dock.Right);
        Content = new Grid { Children = { web, lockPanel } };
        Loaded += async (_, _) =>
        {
            try { await StartAsync(); }
            catch (Exception e)  // e.g. no WebView2 runtime on an old Windows 10: say so here, keep the app running
            {
                CrashLog.Write(e);
                Content = new TextBlock
                {
                    Text = $"The editor couldn't start: {e.Message}\nReinstalling NoteAnywhere installs what it needs.",
                    TextWrapping = System.Windows.TextWrapping.Wrap, Margin = new System.Windows.Thickness(24), Opacity = 0.8,
                };
            }
        };
        NotesModel.Shared.Changed += Push;
        LockSession.Shared.Changed += Push;  // unlocked or locked again: every locked note opens or shuts
    }

    public string? NoteId
    {
        get => noteId;
        set
        {
            if (value == noteId) return;
            noteId = value;
            shown = null;
            ShowLock();
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

    // The scheme list goes through the constructor: the options' CustomSchemeRegistrations starts out null, not empty.
    static Task<CoreWebView2Environment> Environment() => environment ??= CoreWebView2Environment.CreateAsync(null,
        Path.Combine(AppPaths.Data, "WebView2"),
        new CoreWebView2EnvironmentOptions(customSchemeRegistrations:
            [new(NoteStore.ImageScheme) { TreatAsSecure = true, HasAuthorityComponent = false, AllowedOrigins = [$"https://{Host}"] }]));

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
    static bool IsLocked(Note note) => note.Locked || NoteLock.IsEnvelope(note.Text);

    /// What the editor holds: a note's text, or a locked note's opened with the session's password; null while it stays
    /// shut (not unlocked, or a password that doesn't open it: `problem` says why).
    string? Editable(Note note)
    {
        if (!IsLocked(note)) return note.Text;
        if (LockSession.Shared.Password is not { } key) return null;
        try { return NoteLock.Open(note.Text, key); }
        catch (CryptographicException e) { problem.Text = e.Message; return null; }
    }

    /// Shows the editor, or the lock panel while the note stays shut; returns what the editor should hold.
    string ShowLock()
    {
        var text = Current is { } note ? Editable(note) : "";
        shut = text is null;
        web.Visibility = shut ? Visibility.Collapsed : Visibility.Visible;
        lockPanel.Visibility = shut ? Visibility.Visible : Visibility.Collapsed;
        hint.Text = LockSession.Hint is { Length: > 0 } h ? $"Hint: {h}" : "";
        hint.Visibility = hint.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (shut && !Page) Height = double.NaN;  // a card fits the lock, not the hidden editor
        return text ?? "";  // shut: the page keeps nothing of the note
    }

    void Unlock()
    {
        try
        {
            LockSession.Shared.Unlock(password.Password, NotesModel.Shared.Notes);
            password.Clear();
            problem.Text = "";
        }
        catch (CryptographicException e)
        {
            problem.Text = e.Message;
            password.SelectAll();
            password.Focus();
        }
    }

    Task LoadAsync()
    {
        shown = ShowLock();
        var options = new Dictionary<string, object>
        {
            ["toolbar"] = Page ? "selection" : false, ["fontSize"] = Page ? 15 : 13, ["titleLine"] = true, ["page"] = Page,
            ["datePattern"] = Settings.Load().DateFormat is { Length: > 0 } f ? f : DateStyle.Region, ["pages"] = true,
            ["aiName"] = "Phi-4-mini", ["aiPlace"] = "on this PC",  // ✨'s model (WritingModel), named in its menu
        };
        return Call("load", shown, options);
    }

    /// An edit made elsewhere: the editor shows it, unless it's what the editor already holds.
    void Push()
    {
        var text = ShowLock();  // sync may lock the note, and Lock Notes shuts it: the page then holds nothing of it
        if (!ready || Current is null || text == shown) return;
        shown = text;
        _ = Call("set", text);
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
                    if (noteId is null || Current is not { } note || shut) break;  // shut: never written over
                    if (!IsLocked(note)) notes.SaveText(noteId, shown);
                    // Sealed again with the envelope's own salt, so typing doesn't derive a new key each time.
                    else if (LockSession.Shared.Password is { } key) notes.SaveText(noteId, NoteLock.Seal(shown, key, reusing: note.Text));
                    break;
                case "height":
                    // A card sized to its note (the panel), within the Mac's 44–320 points.
                    if (!Page && !shut && msg.TryGetProperty("value", out var h) && h.ValueKind == JsonValueKind.Number) Height = Math.Clamp(h.GetDouble(), 44, 320);
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
                    await Reply(id, await Assistant.Run(WritingModel.Shared, Text("action"), Text("text")));
                    break;
                case "linkPreview":
                    // A pasted link's card or mention, as the Mac's: the pictures become note images, so they show offline.
                    try
                    {
                        if (!Uri.TryCreate(Text("url"), UriKind.Absolute, out var url)) throw new InvalidOperationException("That isn't a web address.");
                        var page = await LinkPreview.FetchAsync(url, LinkPreview.Web, BrowserHost.LargestFrameAsPng);
                        await Reply(id, new { title = page.Title, description = page.Description, icon = page.Icon, image = page.Image });
                    }
                    catch (Exception failure) { await Reply(id, null, failure.Message); }
                    break;
            }
        }
        catch (Exception error) when (id != 0)
        {
            await Reply(id, null, error.Message);
        }
    }
}
