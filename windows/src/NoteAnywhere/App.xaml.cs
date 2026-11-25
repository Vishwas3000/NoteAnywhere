using System.Diagnostics;
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
        hotkeys = new HotKeys();
        hotkeys.Register(0x4D, TogglePanel);  // Alt+Shift+M
        hotkeys.Register(0x20, OpenSearch);   // Alt+Shift+Space
        tray = new Tray(ShowNotes, TogglePanel, OpenSearch, ShowSettings, SendFeedback, Shutdown);
        instance.ListenForShow(() => Dispatcher.Invoke(ShowNotes));
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

    // Phase 2 (D86) brings the floating panel and the search popup; until then both open the notes.
    void TogglePanel() => ShowNotes();
    void OpenSearch() => ShowNotes();

    static void SendFeedback() => Process.Start(new ProcessStartInfo("https://noteanywhere.app/#feedback") { UseShellExecute = true });

    protected override void OnExit(ExitEventArgs e)
    {
        tray?.Dispose();
        hotkeys?.Dispose();
        front?.Dispose();
        instance?.Dispose();
        base.OnExit(e);
    }
}
