using System.Security.Cryptography;
using Microsoft.ML.OnnxRuntimeGenAI;

namespace NoteAnywhere.Core;

/// The ✨ actions' model on Windows: Phi-4-mini-instruct (MIT), ONNX int4 for the CPU, through ONNX Runtime GenAI. The
/// CPU build runs on every x64 and Arm64 PC, with no GPU or driver needed. It isn't part of the app: Settings downloads
/// it once the person agrees (D86), into models/ beside the notes. The app and the browser host each load it on first
/// use and let it go after a few idle minutes, as it holds about 5 GB of memory.
public sealed class WritingModel : IWritingModel
{
    const string Commit = "fc04c8f93df696602fd9f300a30d1bf2e3081347";
    const string Base = $"https://huggingface.co/microsoft/Phi-4-mini-instruct-onnx/resolve/{Commit}/cpu_and_mobile/cpu-int4-rtn-block-32-acc-level-4/";
    /// Every file of that folder but its Python code, with Hugging Face's sizes and SHA-256s (merges.txt isn't in LFS:
    /// its SHA-256 is from a download whose git blob id matched the one Hugging Face lists).
    internal static readonly (string Name, string Url, long Size, string Sha256)[] Files =
    [
        ("added_tokens.json", Base + "added_tokens.json", 249, "d4f2aceb0f20b71dd1f4bcc7e052e4412946bf281840b8f83d39f259571af486"),
        ("config.json", Base + "config.json", 2504, "ac65d86061d3d0d704ee2511fd0eb8713ef19eb6eedba17c3080a4165d5b933b"),
        ("genai_config.json", Base + "genai_config.json", 1520, "0fcfa1e663f2bc867f8dc62fae65dd0924f0a4d68b43d1234df742dd19171470"),
        ("merges.txt", Base + "merges.txt", 2418348, "856ce61180bb689282eed6b3a6838bb1f438399be23aefe9d20eb379791fb4ad"),
        ("model.onnx", Base + "model.onnx", 52118230, "701aa5d185b6a782bc27104a990dd5b634fa507840b7c42f7ee6f1fb812d0b83"),
        ("model.onnx.data", Base + "model.onnx.data", 4856573952, "cb0267fa60befa1a4ade8c98b6d32a3d67f51abbd307c7f793f132e8d9092131"),
        ("special_tokens_map.json", Base + "special_tokens_map.json", 587, "aff38493227d813e29fcf8406e8e90062f1f031aa47d589325e9c31d89ac7cc3"),
        ("tokenizer.json", Base + "tokenizer.json", 15524095, "382cc235b56c725945e149cc25f191da667c836655efd0857b004320e90e91ea"),
        ("tokenizer_config.json", Base + "tokenizer_config.json", 2960, "c565326a315fbe62cda093a59d298828c8f3f823122661325f41f3ba577a7dec"),
        ("vocab.json", Base + "vocab.json", 3910310, "6cb65a857824fa6615bb1782d95d882617a8bbce1da0317118586b36f39e98bd"),
    ];
    /// Prompt and reply together, as the Mac's on-device model: past this the CPU would take minutes, and the cache, sized
    /// to it up front, grows by 256 KB a token.
    const int Context = 4096;
    static readonly TimeSpan Idle = TimeSpan.FromMinutes(5);

    public static WritingModel Shared { get; } = new(Path.Combine(AppPaths.Data, "models", "Phi-4-mini-instruct-cpu-int4"), Files, new HttpClientHandler());

    readonly string folder;
    readonly (string Name, string Url, long Size, string Sha256)[] files;
    readonly HttpClient http;
    readonly SemaphoreSlim gate = new(1, 1);  // one generation at a time, and never unloaded during one
    readonly Timer idle;
    (Model Model, Tokenizer Tokenizer)? loaded;

    internal WritingModel(string folder, (string, string, long, string)[] files, HttpMessageHandler handler)
    {
        this.folder = folder;
        this.files = files;
        http = new HttpClient(handler);
        idle = new Timer(_ => { if (gate.Wait(0)) try { Unload(); } finally { gate.Release(); } });
    }

    /// Complete and checked: the folder only appears, by a rename, once every file has.
    public bool Installed => Directory.Exists(folder);
    public long Size => files.Sum(f => f.Size);
    public string SizeText => $"{Size / 1e9:0.0} GB";

    public string? UnavailableReason => Installed ? null : $"Download the writing model first: Settings ▸ Writing model ({SizeText}, once).";

    public async Task<string> Respond(string instructions, string text, CancellationToken cancel)
    {
        await gate.WaitAsync(cancel).ConfigureAwait(false);
        try { return await Task.Run(() => Generate(instructions, text, cancel), cancel).ConfigureAwait(false); }
        catch (OnnxRuntimeGenAIException e) { throw new InvalidOperationException($"The writing model couldn't finish: {e.Message}", e); }
        finally
        {
            idle.Change(Idle, Timeout.InfiniteTimeSpan);
            gate.Release();
        }
    }

    string Generate(string instructions, string text, CancellationToken cancel)
    {
        if (loaded is null)
        {
            Utils.DisableTelemetryEvents();  // the app sends nothing anywhere (PRIVACY.md)
            var model = new Model(folder);
            loaded = (model, new Tokenizer(model));
        }
        var (phi, tokenizer) = loaded.Value;
        // Phi-4-mini's chat template (its tokenizer_config.json), which adds no start token.
        using var prompt = tokenizer.Encode($"<|system|>{instructions}<|end|><|user|>{text}<|end|><|assistant|>");
        var length = prompt[0].Length;
        var room = 2 * length + 64;  // a rewrite as long as the text, and some
        if (room > Context) throw new InvalidOperationException("This note is too long for the on-device model. Select a part of it and try again.");
        using var options = new GeneratorParams(phi);
        options.SetSearchOption("max_length", room);
        using var generator = new Generator(phi, options);
        generator.AppendTokenSequences(prompt);
        var end = tokenizer.GetEosTokenIds().ToArray();
        List<int> reply = [];
        while (!generator.IsDone())
        {
            cancel.ThrowIfCancellationRequested();
            generator.GenerateNextToken();
            var token = generator.GetSequence(0)[^1];
            if (!end.Contains(token)) reply.Add(token);
        }
        return tokenizer.Decode(reply.ToArray());
    }

    void Unload()
    {
        if (loaded is not var (model, tokenizer)) return;
        tokenizer.Dispose();
        model.Dispose();
        loaded = null;
    }

    /// Downloads every file into a folder of its own, checking each one's size and SHA-256 as it arrives, and only then
    /// renames that folder into place: a cut or cancelled download never looks installed, and is deleted. `progress` gets
    /// the share done, 0 to 1.
    public async Task DownloadAsync(IProgress<double>? progress, CancellationToken cancel)
    {
        if (Installed) return;
        var temp = folder + ".download";
        if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true);  // from a download the app's end cut
        Directory.CreateDirectory(temp);
        try
        {
            long total = Size, done = 0, shown = -1;
            var drive = new DriveInfo(Path.GetFullPath(temp));
            if (drive.AvailableFreeSpace < total + 1_000_000_000)  // a gigabyte to spare, so notes can still be saved
                throw new IOException($"The writing model needs {SizeText} free on {drive.Name}, and there's {drive.AvailableFreeSpace / 1e9:0.0} GB.");
            var buffer = new byte[1 << 20];
            foreach (var (name, url, size, sha256) in files)
            {
                using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel).ConfigureAwait(false);
                response.EnsureSuccessStatusCode();
                await using var source = await response.Content.ReadAsStreamAsync(cancel).ConfigureAwait(false);
                await using var file = File.Create(Path.Combine(temp, name));
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                int read;
                while ((read = await source.ReadAsync(buffer, cancel).ConfigureAwait(false)) > 0)
                {
                    await file.WriteAsync(buffer.AsMemory(0, read), cancel).ConfigureAwait(false);
                    hash.AppendData(buffer, 0, read);
                    done += read;
                    if (done * 1000 / total > shown) { shown = done * 1000 / total; progress?.Report(shown / 1000.0); }
                }
                if (file.Length != size || Convert.ToHexStringLower(hash.GetHashAndReset()) != sha256)
                    throw new InvalidDataException($"{name} didn't arrive intact. Try again.");
            }
            Directory.Move(temp, folder);
        }
        catch
        {
            try { Directory.Delete(temp, recursive: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }  // the next start deletes it
            throw;
        }
    }

    /// Settings' Remove. The rename comes first, so a model that's half deleted never looks installed.
    public async Task RemoveAsync()
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            Unload();
            var doomed = folder + ".removing";
            if (Directory.Exists(doomed)) Directory.Delete(doomed, recursive: true);
            if (!Installed) return;
            Directory.Move(folder, doomed);
            Directory.Delete(doomed, recursive: true);
        }
        finally { gate.Release(); }
    }

    /// At the app's start: what a download the app's end cut, or a removal that failed halfway, left behind.
    public void DeleteLeftovers()
    {
        foreach (var leftover in new[] { folder + ".download", folder + ".removing" })
            try { if (Directory.Exists(leftover)) Directory.Delete(leftover, recursive: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }  // still in use: the next start
    }
}
