# Saves a PNG of one process's main window (or its visible window titled -Title), whatever covers it (GitHub's Arm64 machines show a first-run privacy
# prompt on top), with PrintWindow's PW_RENDERFULLCONTENT so WebView2's content is drawn too. Windows PowerShell 5.1.
param([Parameter(Mandatory)] [int] $ProcessId, [Parameter(Mandatory)] [string] $Out, [string] $Title)
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class WindowShot {
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int max);
    public static IntPtr Find(uint process, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr w, IntPtr d) {
            uint owner; GetWindowThreadProcessId(w, out owner);
            var text = new System.Text.StringBuilder(512); GetWindowText(w, text, 512);
            if (owner == process && IsWindowVisible(w) && text.ToString() == title) { found = w; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static void Save(IntPtr window, string path) {
        Rect r;
        if (!GetWindowRect(window, out r)) throw new Exception("no such window");
        using (var bitmap = new Bitmap(r.Right - r.Left, r.Bottom - r.Top)) {
            using (var g = Graphics.FromImage(bitmap)) {
                IntPtr dc = g.GetHdc();
                bool drawn = PrintWindow(window, dc, 2);
                g.ReleaseHdc(dc);
                if (!drawn) throw new Exception("PrintWindow failed");
            }
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
"@
if ($Title) {
    $window = [WindowShot]::Find([uint32]$ProcessId, $Title)
    if ($window -eq [IntPtr]::Zero) { throw "process $ProcessId shows no window titled '$Title'" }
} else {
    $process = Get-Process -Id $ProcessId
    $process.Refresh()
    $window = $process.MainWindowHandle
    if ($window -eq [IntPtr]::Zero) { throw "process $ProcessId has no window" }
}
[WindowShot]::Save($window, (Join-Path (Get-Location) $Out))
