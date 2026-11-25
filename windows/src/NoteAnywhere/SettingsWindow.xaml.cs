using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using NoteAnywhere.Core;
using NoteAnywhere.Platform;

namespace NoteAnywhere;

/// Settings ▸ General: every change is saved and applied at once, as on the Mac.
public partial class SettingsWindow : Window
{
    bool loading = true;
    CancellationTokenSource? download;

    public SettingsWindow()
    {
        InitializeComponent();
        var s = Settings.Load();
        Select(AppearanceBox, s.Appearance);
        Select(DateBox, s.DateFormat);
        AutoOpenBox.IsChecked = s.OpenNotesByThemselves;
        LoginBox.IsChecked = s.OpenAtLogin;
        ShowWriting();
        loading = false;
    }

    /// The writing model's state: not here (Download, with its size), downloading (Cancel), or here (Remove).
    void ShowWriting(string? problem = null)
    {
        var model = WritingModel.Shared;
        WritingProgress.Visibility = download is null ? Visibility.Collapsed : Visibility.Visible;
        WritingButton.Content = download is not null ? "Cancel" : model.Installed ? "Remove" : $"Download ({model.SizeText})";
        WritingText.Text = problem ?? (download is not null ? "Downloading…"
            : model.Installed ? "On this PC. ✨ in a note proofreads, rewrites, shortens, makes a checklist or a title, and nothing leaves the PC."
            : $"For ✨ in a note: Phi-4-mini, a model that runs on this PC, so nothing leaves it. A {model.SizeText} download from Hugging Face, once.");
    }

    async void OnWritingButton(object sender, RoutedEventArgs e)
    {
        var model = WritingModel.Shared;
        if (download is not null) { download.Cancel(); return; }
        string? problem = null;
        if (model.Installed)
        {
            try { await model.RemoveAsync(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { problem = $"Couldn't remove it: {error.Message}"; }
            ShowWriting(problem);
            return;
        }
        download = new CancellationTokenSource();
        ShowWriting();
        var progress = new Progress<double>(done =>
        {
            WritingProgress.Value = done;
            WritingText.Text = $"Downloading… {done * model.Size / 1e9:0.0} of {model.SizeText}";
        });
        try { await model.DownloadAsync(progress, download.Token); }
        catch (OperationCanceledException) when (download.IsCancellationRequested) { }
        catch (Exception error) { problem = $"The download stopped: {error.Message}"; }
        download = null;
        ShowWriting(problem);
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
