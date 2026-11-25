using System.IO;
using System.Text.Json;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using NoteAnywhere.Core;

namespace NoteAnywhere.Editor;

/// The shared Markdown editor (editor/ and app/editor.html, the same files the Mac app and the browser use) in WebView2.
/// app/editor.html talks to the Mac through webkit.messageHandlers.mn; a one-line shim points that at WebView2's
/// chrome.webview, so the page itself is unchanged (D86).
public sealed class EditorView : ContentControl
{
    const string Host = "editor.noteanywhere";
    static readonly string Options = JsonSerializer.Serialize(new
    {
        toolbar = "selection", fontSize = 15, titleLine = true, page = true, datePattern = "dd/MM/yyyy", pages = false,
    });

    readonly WebView2 web = new();
    string markdown = "";
    bool ready;

    /// Every edit, as Markdown.
    public event Action<string>? Changed;

    public EditorView()
    {
        Content = web;
        Loaded += async (_, _) => await StartAsync();
    }

    public void Show(string text)
    {
        markdown = text;
        if (ready) _ = LoadAsync();
    }

    async Task StartAsync()
    {
        if (web.CoreWebView2 != null) return;
        var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(AppPaths.Data, "WebView2"));
        await web.EnsureCoreWebView2Async(env);
        var core = web.CoreWebView2!;
        core.SetVirtualHostNameToFolderMapping(Host, Path.Combine(AppContext.BaseDirectory, "editor"),
            CoreWebView2HostResourceAccessKind.Allow);
        await core.AddScriptToExecuteOnDocumentCreatedAsync(
            "window.webkit = { messageHandlers: { mn: { postMessage: (m) => window.chrome.webview.postMessage(m) } } };");
        core.Settings.IsStatusBarEnabled = false;
        core.WebMessageReceived += OnMessage;
        core.Navigate($"https://{Host}/editor.html");
    }

    Task LoadAsync() => web.CoreWebView2.ExecuteScriptAsync($"MNHost.load({JsonSerializer.Serialize(markdown)}, {Options})");

    void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        using var doc = JsonDocument.Parse(e.WebMessageAsJson);
        var msg = doc.RootElement;
        switch (msg.GetProperty("type").GetString())
        {
            case "ready":
                ready = true;
                _ = LoadAsync();
                break;
            case "change":
                markdown = msg.GetProperty("markdown").GetString() ?? "";
                Changed?.Invoke(markdown);
                break;
        }
    }
}
