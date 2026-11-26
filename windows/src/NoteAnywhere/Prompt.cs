using System.Security.Cryptography;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using NoteAnywhere.Core;
using NoteAnywhere.Core.Crypto;

namespace NoteAnywhere;

/// Small windows that ask for one thing: a name (New Folder, Rename, Add Website) or the notes password.
static class Prompt
{
    public static string? Ask(Window? owner, string title, string label, string initial = "", string action = "OK")
    {
        var box = new TextBox { Text = initial, MinWidth = 320, Margin = new Thickness(0, 8, 0, 16) };
        var ok = new Button { Content = action, IsDefault = true, MinWidth = 80, Margin = new Thickness(8, 0, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 80 };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, ok } };
        var window = new Window
        {
            Title = title, Owner = owner, SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            Content = new StackPanel { Margin = new Thickness(20), Children = { new TextBlock { Text = label }, box, buttons } },
        };
        ok.Click += (_, _) => window.DialogResult = true;
        box.TextChanged += (_, _) => ok.IsEnabled = box.Text.Trim().Length > 0;
        ok.IsEnabled = initial.Trim().Length > 0;
        window.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return window.ShowDialog() == true ? box.Text.Trim() : null;
    }

    /// Lock Note or Remove Lock while locked notes are shut: the notes password, checked before the window closes.
    public static bool UnlockNotes(Window? owner, IEnumerable<Note> notes)
    {
        var box = Secret("Notes password");
        var problem = Problem();
        var ok = new Button { Content = "Unlock" };
        var rows = new List<UIElement> { new TextBlock { Text = "Enter the notes password." } };
        if (LockSession.Hint is { Length: > 0 } hint) rows.Add(new TextBlock { Text = $"Hint: {hint}", Opacity = 0.6, FontSize = 12 });
        rows.AddRange([box, problem]);
        var window = Dialog(owner, "Unlock Locked Notes", ok, [.. rows]);
        ok.Click += (_, _) =>
        {
            try { LockSession.Shared.Unlock(box.Password, notes); window.DialogResult = true; }
            catch (CryptographicException e) { problem.Text = e.Message; box.SelectAll(); box.Focus(); }
        };
        window.Loaded += (_, _) => box.Focus();
        return window.ShowDialog() == true;
    }

    /// The first Lock Note: the notes password, twice, and a hint, as the Mac's NotesPasswordSheet.
    public static bool SetNotesPassword(Window? owner)
    {
        var password = Secret("Password");
        var verify = Secret("Verify");
        var hint = new TextBox { MinWidth = 320, Margin = new Thickness(0, 4, 0, 8) };
        AutomationProperties.SetName(hint, "Hint (recommended)");
        var problem = Problem();
        var ok = new Button { Content = "Set Password", IsEnabled = false };
        void Check() => ok.IsEnabled = password.Password.Length >= 4 && password.Password == verify.Password && password.Password != hint.Text.Trim();
        password.PasswordChanged += (_, _) => Check();
        verify.PasswordChanged += (_, _) => Check();
        hint.TextChanged += (_, _) => Check();
        var window = Dialog(owner, "Set a Password for Locked Notes", ok,
            new TextBlock { Text = "Locked notes are encrypted with this password, here and wherever they sync.", TextWrapping = TextWrapping.Wrap, MaxWidth = 320, Margin = new Thickness(0, 0, 0, 8) },
            new TextBlock { Text = "Password" }, password, new TextBlock { Text = "Verify" }, verify, new TextBlock { Text = "Hint (recommended)" }, hint,
            new TextBlock { Text = "If you forget this password, your locked notes can't be recovered.", TextWrapping = TextWrapping.Wrap, MaxWidth = 320, Opacity = 0.8 },
            problem);
        ok.Click += (_, _) =>
        {
            try { LockSession.Shared.SetPassword(password.Password, hint.Text.Trim()); window.DialogResult = true; }
            catch (ArgumentException e) { problem.Text = e.Message; }
        };
        window.Loaded += (_, _) => password.Focus();
        return window.ShowDialog() == true;
    }

    static PasswordBox Secret(string name)
    {
        var box = new PasswordBox { MinWidth = 320, Margin = new Thickness(0, 4, 0, 8) };
        AutomationProperties.SetName(box, name);
        return box;
    }

    static TextBlock Problem() => new() { Opacity = 0.8, TextWrapping = TextWrapping.Wrap, MaxWidth = 320 };

    static Window Dialog(Window? owner, string title, Button ok, params UIElement[] rows)
    {
        ok.IsDefault = true;
        ok.MinWidth = 80;
        ok.Margin = new Thickness(8, 0, 0, 0);
        var content = new StackPanel { Margin = new Thickness(20) };
        foreach (var row in rows) content.Children.Add(row);
        content.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0),
            Children = { new Button { Content = "Cancel", IsCancel = true, MinWidth = 80 }, ok },
        });
        return new Window
        {
            Title = title, Owner = owner, SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            Content = content,
        };
    }
}
