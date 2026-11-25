using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// What the sidebar lists, top to bottom: section headers, folders, notes and tags, as the Mac's sidebar (D84).
abstract record SidebarItem;
sealed record HeaderItem(string Title) : SidebarItem;
sealed record FolderItem(string? Id, string Name, int Count, string Glyph, bool Current) : SidebarItem
{
    public FontWeight Weight => Current ? FontWeights.SemiBold : FontWeights.Normal;
}
sealed record TagItem(string Tag, int Count) : SidebarItem
{
    public string Name => "#" + Tag;
}
sealed record NoteItem(Note Note) : SidebarItem
{
    static readonly Dictionary<NoteColor, Color> Swatches = new()
    {
        [NoteColor.Grey] = Color.FromRgb(0x8E, 0x8E, 0x93), [NoteColor.Blue] = Color.FromRgb(0x0A, 0x84, 0xFF),
        [NoteColor.Red] = Color.FromRgb(0xFF, 0x45, 0x3A), [NoteColor.Yellow] = Color.FromRgb(0xFF, 0xD6, 0x0A),
        [NoteColor.Green] = Color.FromRgb(0x30, 0xD1, 0x58), [NoteColor.Pink] = Color.FromRgb(0xFF, 0x37, 0x5F),
        [NoteColor.Purple] = Color.FromRgb(0xBF, 0x5A, 0xF2), [NoteColor.Cyan] = Color.FromRgb(0x64, 0xD2, 0xFF),
        [NoteColor.Orange] = Color.FromRgb(0xFF, 0x9F, 0x0A),
    };

    public string Title => Note.Title;
    public string Date => NoteDates.Short(Note.Edited);
    public string Preview => Note.Preview.Length == 0 ? "No additional text" : Note.Preview;
    // The app's or site's mark before the date (D84): a globe for websites, a window for apps, nothing for plain notes.
    public string SourceGlyph => Note.Kind == NoteKind.Url ? "\uE774" : "\uE737";
    public Visibility SourceVisibility => Note.HasSource ? Visibility.Visible : Visibility.Collapsed;
    public string Source => Note.HasSource ? Note.ShortSource() : "";
    public Brush Strip => Note.Color is { } c ? new SolidColorBrush(Swatches[c]) : Brushes.Transparent;
    public Visibility StarVisibility => Note.Starred ? Visibility.Visible : Visibility.Collapsed;
    public Visibility LockVisibility => Note.Locked ? Visibility.Visible : Visibility.Collapsed;
    public static Color Swatch(NoteColor color) => Swatches[color];
}

/// Rows as compact as the Mac's sidebar (the theme's own are much taller); headers can't be selected or focused.
sealed class SidebarRowStyles : StyleSelector
{
    Style? row, header;

    public override Style? SelectStyle(object item, DependencyObject container)
    {
        if (row is null)
        {
            // Based on the theme's own row style when it can be found; a lookup that throws would end the app.
            row = new Style(typeof(ListBoxItem), Application.Current.TryFindResource(typeof(ListBoxItem)) as Style);
            row.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10, 2, 10, 2)));
            row.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 0.0));
            header = new Style(typeof(ListBoxItem), row);
            header.Setters.Add(new Setter(UIElement.IsHitTestVisibleProperty, false));
            header.Setters.Add(new Setter(UIElement.FocusableProperty, false));
        }
        return item is HeaderItem ? header : row;
    }
}
