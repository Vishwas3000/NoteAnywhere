# Saves a PNG of one process's main window, whatever covers it (GitHub's Arm64 machines show a first-run privacy
# prompt on top), with PrintWindow's PW_RENDERFULLCONTENT so WebView2's content is drawn too. Windows PowerShell 5.1.
param([Parameter(Mandatory)] [int] $ProcessId, [Parameter(Mandatory)] [string] $Out)
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class WindowShot {
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
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
$process = Get-Process -Id $ProcessId
$process.Refresh()
if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw "process $ProcessId has no window" }
[WindowShot]::Save($process.MainWindowHandle, (Join-Path (Get-Location) $Out))
