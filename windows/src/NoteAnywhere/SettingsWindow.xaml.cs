using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using NoteAnywhere.Core;
using NoteAnywhere.Core.Sync;
using NoteAnywhere.Platform;

namespace NoteAnywhere;

/// Settings ▸ General, where every change is saved and applied at once, and Settings ▸ Sync, as on the Mac.
public partial class SettingsWindow : Window
{
    readonly CloudSync sync;
    bool loading = true;
    string step = "";
    CancellationTokenSource? download;

    public SettingsWindow(CloudSync sync)
    {
        InitializeComponent();
        this.sync = sync;
        var s = Settings.Load();
        Select(AppearanceBox, s.Appearance);
        Select(DateBox, s.DateFormat);
        AutoOpenBox.IsChecked = s.OpenNotesByThemselves;
        LoginBox.IsChecked = s.OpenAtLogin;
        ShowWriting();
        loading = false;
        sync.Changed += () => Dispatcher.BeginInvoke(ShowSync);
        ShowSync();
    }

    public void ShowSyncTab() => Tabs.SelectedItem = SyncTab;

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

    // Sync: one step at a time (sign in, the code, the passphrase), then the account, then any error.

    void ShowSync()
    {
        var signedIn = sync.Email != null;
        var now = !signedIn ? (sync.PendingEmail != null ? "code" : "sign in") : sync.Vault switch
        {
            CloudSync.VaultStep.Create => "create",
            CloudSync.VaultStep.Enter => "enter",
            CloudSync.VaultStep.Ready => "ready",
            _ => "checking",
        };
        Show(SignInPanel, now == "sign in");
        Show(CodePanel, now == "code");
        Show(CreatePanel, now == "create");
        Show(EnterPanel, now == "enter");
        Show(CheckingText, now == "checking");
        Show(AccountPanel, signedIn);
        Show(SyncedRow, now == "ready");  // before the passphrase there's nothing to sync, so no dead button
        Show(SyncNowButton, now == "ready");
        AccountEmail.Text = sync.Email;
        SyncedText.Text = sync.Busy ? "Syncing…" : sync.LastSynced is { } at ? When(at.LocalDateTime) : "Not yet";
        SentTo.Text = $"We sent a sign-in link to {sync.PendingEmail}. It expires in an hour.";
        ErrorText.Text = sync.Error is { } error ? "⚠ " + error : "";
        Show(ErrorText, sync.Error != null);
        if (now != step)
        {
            step = now;
            if (signedIn) CodeBox.Clear();
            if (now == "ready")
            {
                NewPassphrase.Clear();
                AgainPassphrase.Clear();
                EnterPassphrase.Clear();
            }
            (now switch { "sign in" => EmailBox, "code" => CodeBox, "create" => NewPassphrase, "enter" => EnterPassphrase, _ => (Control?)null })?.Focus();
        }
        Enable();
    }

    static string When(DateTime at) => at.Date == DateTime.Today ? $"Today at {at:t}" : $"{at:g}";

    static void Show(UIElement element, bool shown) => element.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;

    /// The buttons, prompts and passphrase hint follow what's typed.
    void Enable()
    {
        var idle = !sync.Busy;
        GoogleButton.IsEnabled = idle;
        SendLinkButton.IsEnabled = idle && EmailBox.Text.Contains('@');
        SignInButton.IsEnabled = idle && CodeBox.Text.Count(char.IsDigit) is >= 6 and <= 8;
        CreateButton.IsEnabled = idle && PassphraseIsValid;
        UnlockButton.IsEnabled = idle && EnterPassphrase.Password.Length > 0;
        SyncNowButton.IsEnabled = idle;
        Show(EmailPrompt, EmailBox.Text.Length == 0);
        Show(CodePrompt, CodeBox.Text.Length == 0);
        Show(NewPrompt, NewPassphrase.Password.Length == 0);
        Show(AgainPrompt, AgainPassphrase.Password.Length == 0);
        Show(EnterPrompt, EnterPassphrase.Password.Length == 0);
        PassphraseHint.Text = Hint();
        Show(PassphraseHint, Hint() != null);
    }

    bool PassphraseIsValid => Characters(NewPassphrase.Password) >= 8 && NewPassphrase.Password == AgainPassphrase.Password;

    /// Why Turn On is still greyed out, once there's something typed to explain.
    string? Hint()
    {
        var missing = 8 - Characters(NewPassphrase.Password);
        if (NewPassphrase.Password.Length == 0) return null;
        if (missing > 0) return missing == 1 ? "1 more character to go." : $"{missing} more characters to go.";
        if (AgainPassphrase.Password.Length > 0 && AgainPassphrase.Password != NewPassphrase.Password) return "The two passphrases don't match yet.";
        return null;
    }

    static int Characters(string text) => new StringInfo(text).LengthInTextElements;  // as Swift counts them: an emoji is one

    void OnTyped(object sender, RoutedEventArgs e) => Enable();

    /// Google's page opens in the browser; Supabase sends it back as a memorynotes:// link (App.OpenLink).
    void OnGoogle(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(CloudSync.GoogleUrl) { UseShellExecute = true }); }
        catch (Win32Exception ex) { sync.Error = ex.Message; }
    }

    void OnSendLink(object sender, RoutedEventArgs e) => SendLink();
    void OnEmailKey(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) SendLink(); }
    void SendLink() { if (SendLinkButton.IsEnabled) _ = sync.SendLink(EmailBox.Text); }

    void OnSignIn(object sender, RoutedEventArgs e) => Verify();
    void OnCodeKey(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) Verify(); }
    void Verify() { if (SignInButton.IsEnabled) _ = sync.Verify(CodeBox.Text); }

    void OnDifferentEmail(object sender, RoutedEventArgs e)
    {
        sync.CancelCode();
        CodeBox.Clear();
    }

    void OnNewPassphraseKey(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) AgainPassphrase.Focus(); }
    void OnAgainKey(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) Create(); }
    void OnCreate(object sender, RoutedEventArgs e) => Create();
    void Create() { if (CreateButton.IsEnabled) _ = sync.CreateVault(NewPassphrase.Password); }

    void OnEnterKey(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) Unlock(); }
    void OnUnlock(object sender, RoutedEventArgs e) => Unlock();
    void Unlock() { if (UnlockButton.IsEnabled) _ = sync.EnterVault(EnterPassphrase.Password); }

    void OnSyncNow(object sender, RoutedEventArgs e) => sync.SyncNow();
    void OnSignOut(object sender, RoutedEventArgs e) => sync.SignOut();

    // Kept for the next open, like the Mac's Settings window.
    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }
}
