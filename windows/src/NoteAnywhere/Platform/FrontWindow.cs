using System.Diagnostics;
using System.IO;
using NoteAnywhere.Core;

namespace NoteAnywhere.Platform;

/// The app and window in front, as a place for notes: the Mac's FrontWindow, fed by Windows' foreground and
/// title-change events instead of Accessibility notifications. Our own windows never count, so the panel keeps showing
/// the place you came from while you type in it.
public sealed record FrontContext(string AppId, string AppName, string Title, string Target);

public sealed class FrontWindow : IDisposable
{
    readonly Win32.WinEventProc callback;  // held here: the hook calls it for as long as it's installed
    readonly IntPtr foregroundHook, titleHook;
    readonly uint ourProcess = (uint)Environment.ProcessId;
    IntPtr window;

    public FrontContext? Current { get; private set; }
    public event Action<FrontContext>? Changed;

    /// Call on a thread with a message loop (the UI thread): the hooks deliver through it.
    public FrontWindow()
    {
        callback = OnEvent;
        foregroundHook = Win32.SetWinEventHook(Win32.EVENT_SYSTEM_FOREGROUND, Win32.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, callback, 0, 0, Win32.WINEVENT_OUTOFCONTEXT);
        titleHook = Win32.SetWinEventHook(Win32.EVENT_OBJECT_NAMECHANGE, Win32.EVENT_OBJECT_NAMECHANGE, IntPtr.Zero, callback, 0, 0, Win32.WINEVENT_OUTOFCONTEXT);
        Look(Win32.GetForegroundWindow());
    }

    void OnEvent(IntPtr hook, uint eventType, IntPtr changed, int idObject, int idChild, uint thread, uint time)
    {
        if (eventType == Win32.EVENT_SYSTEM_FOREGROUND) Look(changed);
        else if (idObject == Win32.OBJID_WINDOW && idChild == 0 && changed == window) Look(changed);  // its title changed
    }

    void Look(IntPtr candidate)
    {
        if (candidate == IntPtr.Zero) return;
        Win32.GetWindowThreadProcessId(candidate, out var process);
        if (process == ourProcess) return;
        window = candidate;
        if (Describe(candidate, process) is not { } context || context == Current) return;
        Current = context;
        Changed?.Invoke(context);
    }

    static FrontContext? Describe(IntPtr window, uint process)
    {
        var path = Win32.ProcessPath(process);
        // A Store app's window belongs to ApplicationFrameHost; the app itself owns a child window.
        if (path != null && Path.GetFileNameWithoutExtension(path).Equals("ApplicationFrameHost", StringComparison.OrdinalIgnoreCase))
        {
            uint inner = 0;
            Win32.EnumChildWindows(window, (child, _) =>
            {
                Win32.GetWindowThreadProcessId(child, out var owner);
                if (owner == process) return true;
                inner = owner;
                return false;
            }, IntPtr.Zero);
            if (inner != 0) path = Win32.ProcessPath(inner) ?? path;
        }
        if (path == null) return null;
        var exe = Path.GetFileNameWithoutExtension(path);
        var info = FileVersionInfo.GetVersionInfo(path);
        var name = new[] { info.FileDescription, info.ProductName, exe }.First(n => !string.IsNullOrWhiteSpace(n))!.Trim();
        var title = Win32.WindowTitle(window);
        var id = WindowsApps.Id(exe);
        return new FrontContext(id, name, title, WindowContext.Target(id, name, title));
    }

    public void Dispose()
    {
        Win32.UnhookWinEvent(foregroundHook);
        Win32.UnhookWinEvent(titleHook);
    }
}
