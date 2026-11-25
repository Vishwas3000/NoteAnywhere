using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace NoteAnywhere.Core.Tests;

/// The writing model's download, check, install and removal, against a stand-in for Hugging Face: the model itself never
/// downloads here (4.9 GB), and never runs; the Windows CI's writing-model workflow does both.
public class WritingModelTests
{
    /// Hugging Face, played by a dictionary: a file's bytes by its name, or 404.
    sealed class Hub(Dictionary<string, byte[]> files) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel) =>
            Task.FromResult(files.TryGetValue(request.RequestUri!.Segments[^1], out var data)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(data) }
                : new HttpResponseMessage(HttpStatusCode.NotFound));
    }

    /// Records the shares reported, and cancels once one passes `cancelAt`.
    sealed class Progress(CancellationTokenSource? cancel = null, double cancelAt = 2) : IProgress<double>
    {
        public readonly List<double> Shares = [];
        public void Report(double share)
        {
            Shares.Add(share);
            if (share > cancelAt) cancel?.Cancel();
        }
    }

    static readonly Dictionary<string, byte[]> Files = new()
    {
        ["genai_config.json"] = Encoding.UTF8.GetBytes("{}"),
        ["model.onnx.data"] = RandomNumberGenerator.GetBytes(3 << 20),  // several reads of the 1 MB buffer
    };

    static (string, string, long, string)[] Pinned(Dictionary<string, byte[]> files) =>
        [.. files.Select(f => (f.Key, "https://huggingface.test/" + f.Key, (long)f.Value.Length, Convert.ToHexStringLower(SHA256.HashData(f.Value))))];

    static string NewFolder() => Path.Combine(AppPaths.Data, "models", Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task DownloadsChecksMovesIntoPlaceAndRemoves()
    {
        var folder = NewFolder();
        Directory.CreateDirectory(folder + ".download");  // what a download the app's end cut left
        File.WriteAllText(Path.Combine(folder + ".download", "model.onnx.data"), "half");
        var model = new WritingModel(folder, Pinned(Files), new Hub(Files));
        Assert.False(model.Installed);
        Assert.NotNull(model.UnavailableReason);

        var progress = new Progress();
        await model.DownloadAsync(progress, CancellationToken.None);
        Assert.True(model.Installed);
        Assert.Null(model.UnavailableReason);
        Assert.False(Directory.Exists(folder + ".download"));
        foreach (var (name, data) in Files) Assert.Equal(data, File.ReadAllBytes(Path.Combine(folder, name)));
        Assert.Equal(1, progress.Shares[^1]);
        Assert.Equal(progress.Shares.Order(), progress.Shares);

        await model.RemoveAsync();
        Assert.False(model.Installed);
        Assert.False(Directory.Exists(folder + ".removing"));
    }

    [Fact]
    public async Task AFileThatIsntIntactLeavesNothing()
    {
        var folder = NewFolder();
        var tampered = new Dictionary<string, byte[]>(Files) { ["model.onnx.data"] = RandomNumberGenerator.GetBytes(3 << 20) };
        var model = new WritingModel(folder, Pinned(Files), new Hub(tampered));
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => model.DownloadAsync(null, CancellationToken.None));
        Assert.Contains("model.onnx.data", error.Message);
        Assert.False(model.Installed);
        Assert.False(Directory.Exists(folder + ".download"));

        var missing = new WritingModel(folder, Pinned(Files), new Hub([]));
        await Assert.ThrowsAsync<HttpRequestException>(() => missing.DownloadAsync(null, CancellationToken.None));
        Assert.False(missing.Installed);
        Assert.False(Directory.Exists(folder + ".download"));
    }

    [Fact]
    public async Task ACancelledDownloadLeavesNothing()
    {
        var folder = NewFolder();
        using var cancel = new CancellationTokenSource();
        var model = new WritingModel(folder, Pinned(Files), new Hub(Files));
        var progress = new Progress(cancel, cancelAt: 0.3);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => model.DownloadAsync(progress, cancel.Token));
        Assert.True(progress.Shares[^1] < 1);
        Assert.False(model.Installed);
        Assert.False(Directory.Exists(folder + ".download"));
    }

    [Fact]
    public void TheAppsStartDeletesLeftovers()
    {
        var folder = NewFolder();
        foreach (var leftover in new[] { folder + ".download", folder + ".removing" })
        {
            Directory.CreateDirectory(leftover);
            File.WriteAllText(Path.Combine(leftover, "model.onnx.data"), "half");
        }
        new WritingModel(folder, Pinned(Files), new Hub(Files)).DeleteLeftovers();
        Assert.Empty(Directory.GetDirectories(Path.GetDirectoryName(folder)!, Path.GetFileName(folder) + "*"));
    }

    /// The editor's ✨ before the model is here: where to get it, and how big it is.
    [Fact]
    public async Task UntilItsDownloadedTheEditorSaysWhereToGetIt()
    {
        var model = new WritingModel(NewFolder(), WritingModel.Files, new Hub([]));
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Assistant.Run(model, "title", "Groceries for Saturday"));
        Assert.Equal("Download the writing model first: Settings ▸ Writing model (4.9 GB, once).", error.Message);
        Assert.Equal("Unknown action.", (await Assert.ThrowsAsync<InvalidOperationException>(() => Assistant.Run(model, "translate", "text"))).Message);
    }

    [Fact]
    public void TheRealModelIsPinnedFileByFile()
    {
        Assert.Equal(10, WritingModel.Files.Select(f => f.Name).Distinct().Count());
        Assert.All(WritingModel.Files, f =>
        {
            Assert.Matches("^[0-9a-f]{64}$", f.Sha256);
            Assert.StartsWith("https://huggingface.co/microsoft/Phi-4-mini-instruct-onnx/resolve/fc04c8f93df696602fd9f300a30d1bf2e3081347/cpu_and_mobile/cpu-int4-rtn-block-32-acc-level-4/", f.Url);
            Assert.EndsWith("/" + f.Name, f.Url);
        });
        Assert.Equal(4_930_552_755, WritingModel.Files.Sum(f => f.Size));
    }
}
