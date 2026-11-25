using System.Windows.Interop;

namespace NoteAnywhere.Platform;

/// Alt+Shift+M shows or hides the floating panel and Alt+Shift+Space opens search, from any app, as ⌥⇧M and ⌥⇧Space
/// do on the Mac. Registered on a message-only window; a key another program already holds is reported, not taken.
public sealed class HotKeys : IDisposable
{
    readonly HwndSource sink = new(new HwndSourceParameters("NoteAnywhereHotKeys") { ParentWindow = new IntPtr(-3) });  // HWND_MESSAGE
    readonly Dictionary<int, Action> actions = [];

    public HotKeys() => sink.AddHook(Hook);

    /// False when another program holds the key already.
    public bool Register(uint key, Action action)
    {
        var id = actions.Count + 1;
        if (!Win32.RegisterHotKey(sink.Handle, id, Win32.MOD_ALT | Win32.MOD_SHIFT | Win32.MOD_NOREPEAT, key)) return false;
        actions[id] = action;
        return true;
    }

    IntPtr Hook(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == Win32.WM_HOTKEY && actions.TryGetValue(wParam.ToInt32(), out var action))
        {
            action();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        foreach (var id in actions.Keys) Win32.UnregisterHotKey(sink.Handle, id);
        sink.Dispose();
    }
}
