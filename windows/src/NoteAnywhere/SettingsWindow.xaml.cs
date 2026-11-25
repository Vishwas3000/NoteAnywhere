using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using NoteAnywhere.Core;
using NoteAnywhere.Platform;

namespace NoteAnywhere;

/// Settings ▸ General: every change is saved and applied at once, as on the Mac.
public partial class SettingsWindow : Window
{
    bool loading = true;

    public SettingsWindow()
    {
        InitializeComponent();
        var s = Settings.Load();
        Select(AppearanceBox, s.Appearance);
        Select(DateBox, s.DateFormat);
        AutoOpenBox.IsChecked = s.OpenNotesByThemselves;
        LoginBox.IsChecked = s.OpenAtLogin;
        loading = false;
    }

    static void Select(ComboBox box, string tag) =>
        box.SelectedItem = box.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == tag) ?? box.Items[0];

    static string Chosen(ComboBox box) => (string)((ComboBoxItem)box.SelectedItem).Tag;

    void OnChanged(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        var s = Settings.Load() with
        {
            Appearance = Chosen(AppearanceBox),
            DateFormat = Chosen(DateBox),
            OpenNotesByThemselves = AutoOpenBox.IsChecked == true,
            OpenAtLogin = LoginBox.IsChecked == true,
        };
        s.Save();
        Appearance.Apply(s.Appearance);
        OpenAtLogin.Apply(s.OpenAtLogin);
    }

    // Kept for the next open, like the Mac's Settings window.
    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }
}
