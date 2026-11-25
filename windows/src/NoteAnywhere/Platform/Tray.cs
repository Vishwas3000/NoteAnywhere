using System.Drawing;
using Forms = System.Windows.Forms;

namespace NoteAnywhere.Platform;

/// The notification-area icon and its menu, the Mac's menu-bar item: a click opens the notes; the menu has the rest.
sealed class Tray : IDisposable
{
    readonly Forms.NotifyIcon icon;

    public Tray(Action openNotes, Action togglePanel, Action search, Action settings, Action feedback, Action welcome, Action quit)
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Notes", null, (_, _) => openNotes());
        menu.Items.Add("Show/Hide Panel\tAlt+Shift+M", null, (_, _) => togglePanel());
        menu.Items.Add("Search Notes\tAlt+Shift+Space", null, (_, _) => search());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Settings…", null, (_, _) => settings());
        menu.Items.Add("Send Feedback…", null, (_, _) => feedback());
        menu.Items.Add("Welcome to NoteAnywhere", null, (_, _) => welcome());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit NoteAnywhere", null, (_, _) => quit());
        icon = new Forms.NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!),
            Text = "NoteAnywhere",
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) openNotes(); };
    }

    public void Dispose()
    {
        icon.Visible = false;  // or a dead icon lingers in the notification area until the pointer passes over it
        icon.Dispose();
    }
}
