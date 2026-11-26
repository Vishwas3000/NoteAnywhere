using System.IO;
using System.Windows.Media.Imaging;
using NoteAnywhere.Core;

namespace NoteAnywhere.Platform;

/// This program as the browsers' native messaging host (NativeHost in Core). Chrome and its kin start it with the
/// extension's origin (and on Windows --parent-window=…), Firefox with the path of the manifest it read (on Windows
/// BrowserRegistration's .firefox.json), then the add-on's id.
static class BrowserHost
{
    public static bool IsHost(string[] args) => args is [var first, ..]
        && (first.StartsWith("chrome-extension://", StringComparison.Ordinal)
            || Path.GetFileName(first) is BrowserRegistration.HostName + ".json" or BrowserRegistration.HostName + ".firefox.json");

    public static int Run()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => CrashLog.Write(e.ExceptionObject);
        using var input = Console.OpenStandardInput();
        using var output = Console.OpenStandardOutput();
        Console.SetOut(Console.Error);  // stdout carries replies and nothing else
        new NativeHost(toPng: LargestFrameAsPng).Run(input, output);
        return 0;
    }

    /// An ICO or BMP as a PNG of its largest frame, as the Mac's LinkPreview.picture makes them.
    internal static byte[] LargestFrameAsPng(byte[] picture)
    {
        var decoder = BitmapDecoder.Create(new MemoryStream(picture), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(decoder.Frames.MaxBy(frame => frame.PixelWidth)!);
        using var png = new MemoryStream();
        encoder.Save(png);
        return png.ToArray();
    }
}
