using System.Windows;
using System.Windows.Controls;

namespace NoteAnywhere;

/// A small "name this" window: New Folder, Rename, Add Website.
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
}
