using System.Diagnostics;
using System.Windows;

namespace NoteAnywhere;

/// Shown once, the first time the notes window opens (the tray's Welcome to NoteAnywhere brings it back), as the Mac's
/// WelcomeView. Windows needs no permission for notes to follow the window in front, so the steps are the shortcuts
/// and the browser extension.
public partial class WelcomeWindow : Window
{
    /// The Mac's BrowserBridge.extensionPage until the Web Store lists the extension: the latest release, whose notes
    /// say how to add it.
    const string ExtensionPage = "https://github.com/Vishwas3000/NoteAnywhere/releases/latest";

    public WelcomeWindow() => InitializeComponent();

    void OnGetExtension(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(ExtensionPage) { UseShellExecute = true });

    void OnGetStarted(object sender, RoutedEventArgs e) => Close();
}
