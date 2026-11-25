using System.Windows;
using NoteAnywhere.Core;
using NoteAnywhere.Platform;

namespace NoteAnywhere;

/// The app lives in the notification area, so the panel can follow the window in front; closing a window only hides it.
public partial class App : Application
{
    SingleInstance? instance;
    FrontWindow? front;
    HotKeys? hotkeys;
    Tray? tray;
    MainWindow? main;
    SettingsWindow? settings;
    PanelWindow? panel;

    public FrontWindow? Front => front;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        instance = new SingleInstance();
        if (!instance.IsFirst)
        {
            instance.ShowTheFirst();
            Shutdown();
            return;
        }
        var saved = Settings.Load();
        Appearance.Apply(saved.Appearance);
        OpenAtLogin.Apply(saved.OpenAtLogin);
        BrowserRegistration.RegisterThisApp();
        front = new FrontWindow();
        panel = new PanelWindow();
        front.Changed += OnFront;
        hotkeys = new HotKeys();
        hotkeys.Register(0x4D, TogglePanel);  // Alt+Shift+M
        hotkeys.Register(0x20, OpenSearch);   // Alt+Shift+Space
        tray = new Tray(ShowNotes, TogglePanel, OpenSearch, ShowSettings, SendFeedback, Shutdown);
        instance.ListenForShow(() => Dispatcher.Invoke(ShowNotes));
        if (e.Args.Contains("--seed-sample-notes")) SampleNotes.SeedIfEmpty();
        if (!e.Args.Contains("--background")) ShowNotes();
    }

    public void ShowNotes()
    {
        main ??= new MainWindow();
        main.Show();
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Activate();
    }

    void ShowSettings()
    {
        settings ??= new SettingsWindow();
        settings.Show();
        settings.Activate();
    }

    /// The Mac's OverlayController: the panel opens by itself when the place in front has app notes (unless Settings
    /// says not to), follows while it's open, and hides on a place without notes. A page's own notes are left to the
    /// browser extension's panel (D69).
    void OnFront(FrontContext c)
    {
        var notes = PanelWindow.NotesFor(c);
        if (notes.Count == 0) { panel?.Hide(); return; }
        var auto = Settings.Load().OpenNotesByThemselves && notes.Any(n => n.Kind == NoteKind.App);
        if (panel!.IsVisible || auto) panel.ShowFor(c, takeFocus: false);
    }

    /// Alt+Shift+M: unlike opening by itself, this takes the keyboard, with the cursor in the newest note.
    void TogglePanel()
    {
        if (panel!.IsVisible) panel.Hide();
        else if (front?.Current is { } c) panel.ShowFor(c, takeFocus: true);
    }

    // The search popup comes next (D86); until then Alt+Shift+Space opens the notes window's search.
    void OpenSearch() => ShowNotes();

    public void OpenNote(string id)
    {
        ShowNotes();
        main!.Open(id);
    }

    static void SendFeedback()
    {
        var window = new FeedbackWindow();
        window.Show();
        window.Activate();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        tray?.Dispose();
        hotkeys?.Dispose();
        front?.Dispose();
        instance?.Dispose();
        base.OnExit(e);
    }
}
