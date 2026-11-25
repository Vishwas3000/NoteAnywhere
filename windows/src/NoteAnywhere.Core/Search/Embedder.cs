using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.Tokenizers;

namespace NoteAnywhere.Core.Search;

/// all-MiniLM-L6-v2, run as the Mac's SearchIndex runs it through swift-embeddings: the first 256 tokens, the mean of
/// their vectors, L2-normalised. The ONNX export and its vocabulary come from Hugging Face on first use (~90 MB), pinned
/// to one commit and checked by SHA-256.
public sealed partial class Embedder(string folder) : IDisposable
{
    /// The embeddings table's model column, as the Mac writes it (NoteStore.embeddingModel).
    public const string Model = "sentence-transformers/all-MiniLM-L6-v2";

    /// The commit the Mac's own download came from (its models/…/.cache metadata says so).
    const string Commit = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41";
    const string Base = $"https://huggingface.co/{Model}/resolve/{Commit}/";
    internal static readonly (string Name, string Url, string Sha256)[] Files =
    [
        ("model.onnx", Base + "onnx/model.onnx", "6fd5d72fe4589f189f8ebc006442dbb529bb7ce38f8082112682524616046452"),
        ("vocab.txt", Base + "vocab.txt", "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"),
    ];
    const int MaxTokens = 256;  // MiniLM was trained on 256 tokens; longer notes are truncated

    static readonly HttpClient Http = new();

    readonly Lock gate = new();
    Task<(InferenceSession, BertTokenizer)?>? loading;

    /// The app's copy, beside the notes.
    public static string DefaultFolder => Path.Combine(AppPaths.Data, "models", "all-MiniLM-L6-v2");

    public Embedder() : this(DefaultFolder) { }

    /// Whether the model is on disk, so embedding won't start its download (the Mac's SearchIndex.hasModel).
    public bool HasModel => Files.All(file => File.Exists(Path.Combine(folder, file.Name)));

    /// Null when there's no model yet and it can't be downloaded (offline): search then matches words only.
    public async Task<float[]?> EmbedAsync(string text)
    {
        if (await ModelAsync().ConfigureAwait(false) is not (var session, var tokenizer)) return null;
        try { return await Task.Run(() => Embed(session, tokenizer, text)).ConfigureAwait(false); }
        catch (OnnxRuntimeException e)  // as the Mac's encode failing: no vector, and indexing waits for the next update
        {
            Console.Error.WriteLine($"NoteAnywhere: couldn't embed a text: {e.Message}");
            return null;
        }
    }

    public void Dispose()
    {
        if (loading is { IsCompletedSuccessfully: true, Result: (var session, _) }) session.Dispose();
    }

    async Task<(InferenceSession, BertTokenizer)?> ModelAsync()
    {
        Task<(InferenceSession, BertTokenizer)?> task;
        lock (gate) task = loading ??= Task.Run(LoadAsync);
        var model = await task.ConfigureAwait(false);
        if (model is null)
            lock (gate) if (loading == task) loading = null;  // try again on the next search, e.g. once back online
        return model;
    }

    async Task<(InferenceSession, BertTokenizer)?> LoadAsync()
    {
        try
        {
            Directory.CreateDirectory(folder);
            foreach (var (name, url, sha256) in Files)
                await DownloadAsync(url, Path.Combine(folder, name), sha256).ConfigureAwait(false);
            return (new InferenceSession(Path.Combine(folder, "model.onnx")), CreateTokenizer(Path.Combine(folder, "vocab.txt")));
        }
        catch (Exception e)  // any failure means words-only search until the next attempt
        {
            Console.Error.WriteLine($"NoteAnywhere: search model unavailable, keyword search only: {e.Message}");
            return null;
        }
    }

    /// Downloads `url` to `path` unless it's there, refusing a file whose SHA-256 isn't `sha256`. Only a checked file is
    /// renamed into place, so one that exists was checked.
    internal static async Task DownloadAsync(string url, string path, string sha256)
    {
        if (File.Exists(path)) return;
        var temp = $"{path}.{Guid.NewGuid():N}.tmp";  // its own name: the app and the browser host may download at once
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(10));
            await using (var download = await Http.GetStreamAsync(url, timeout.Token).ConfigureAwait(false))
            await using (var file = File.Create(temp))
                await download.CopyToAsync(file, timeout.Token).ConfigureAwait(false);
            string actual;
            await using (var file = File.OpenRead(temp))
                actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(file).ConfigureAwait(false));
            if (actual != sha256) throw new InvalidDataException($"{url} has SHA-256 {actual}, not {sha256}");
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            File.Delete(temp);
        }
    }

    // Normalize and Words do what the Mac's tokenizer does before WordPiece; ML.Tokenizers' own basic tokenization
    // deletes line breaks (joining one line's last word to the next line's first) and drops symbols such as "$" and "=".
    internal static BertTokenizer CreateTokenizer(string vocab) => BertTokenizer.Create(vocab, new BertOptions
    {
        ApplyBasicTokenization = false,
        SplitOnSpecialTokens = false,
        PreTokenizer = new RegexPreTokenizer(Words(), null),
    });

    /// [CLS], the text's WordPiece ids, [SEP]; cut to the first 256 as swift-embeddings does, so a long note loses its [SEP].
    /// "[MASK]" and the like in the text are those tokens: the Mac's tokenizer splits them out before anything else.
    internal static long[] TokenIds(BertTokenizer tokenizer, string text)
    {
        List<int> ids = [tokenizer.ClassificationTokenId];
        var start = 0;
        foreach (Match special in SpecialToken().Matches(text))
        {
            ids.AddRange(tokenizer.EncodeToIds(Normalize(text[start..special.Index]), addSpecialTokens: false));
            ids.AddRange(tokenizer.EncodeToIds(special.Value, addSpecialTokens: false, considerPreTokenization: false));
            start = special.Index + special.Length;
        }
        ids.AddRange(tokenizer.EncodeToIds(Normalize(text[start..]), addSpecialTokens: false));
        ids.Add(tokenizer.SeparatorTokenId);
        return [.. ids.Take(MaxTokens).Select(id => (long)id)];
    }

    internal static float[] Embed(InferenceSession session, BertTokenizer tokenizer, string text)
    {
        var ids = TokenIds(tokenizer, text);
        long[] shape = [1, ids.Length];
        using var input = OrtValue.CreateTensorValueFromMemory(ids, shape);
        using var mask = OrtValue.CreateTensorValueFromMemory(Enumerable.Repeat(1L, ids.Length).ToArray(), shape);
        using var types = OrtValue.CreateTensorValueFromMemory(new long[ids.Length], shape);
        using var options = new RunOptions();
        using var outputs = session.Run(options, ["input_ids", "attention_mask", "token_type_ids"], [input, mask, types], ["last_hidden_state"]);
        var hidden = outputs[0].GetTensorDataAsSpan<float>();
        // One text, no padding: every token is in the attention mask, so the masked mean is the plain mean.
        var vector = new float[hidden.Length / ids.Length];
        for (var token = 0; token < ids.Length; token++)
            for (var d = 0; d < vector.Length; d++) vector[d] += hidden[token * vector.Length + d];
        for (var d = 0; d < vector.Length; d++) vector[d] /= ids.Length;
        var norm = Math.Max(MathF.Sqrt(vector.Sum(x => x * x)), 1e-9f);  // swift-embeddings' normalizeEmbeddings
        for (var d = 0; d < vector.Length; d++) vector[d] /= norm;
        return vector;
    }

    /// What the Mac's tokenizer (swift-transformers' BertNormalizer) does first: tabs and line breaks become spaces, CJK
    /// ideographs stand apart, accents go (NFD without its nonspacing marks, never recomposed), then lower case.
    internal static string Normalize(string text)
    {
        Span<char> utf16 = stackalloc char[2];
        var spaced = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())  // a lone surrogate comes out as U+FFFD, as in a Swift string
        {
            var chars = utf16[..rune.EncodeToUtf16(utf16)];
            if (rune.Value is '\t' or '\n' or '\r') spaced.Append(' ');
            else if (IsCjk(rune.Value)) spaced.Append(' ').Append(chars).Append(' ');
            else spaced.Append(chars);
        }
        var plain = new StringBuilder(spaced.Length);
        foreach (var rune in spaced.ToString().Normalize(NormalizationForm.FormD).EnumerateRunes())
            if (Rune.GetUnicodeCategory(rune) != UnicodeCategory.NonSpacingMark) plain.Append(utf16[..rune.EncodeToUtf16(utf16)]);
        return plain.ToString().ToLowerInvariant();
    }

    static bool IsCjk(int c) => c is >= 0x4E00 and <= 0x9FFF or >= 0x3400 and <= 0x4DBF or >= 0x20000 and <= 0x2A6DF
        or >= 0x2A700 and <= 0x2B73F or >= 0x2B740 and <= 0x2B81F or >= 0x2B820 and <= 0x2CEAF or >= 0xF900 and <= 0xFAFF
        or >= 0x2F800 and <= 0x2FA1F;

    /// swift-transformers' BertPreTokenizer: a run of anything but white space and punctuation, or one punctuation mark,
    /// where punctuation is \p{P} and ASCII's other symbols. (.NET's \s is ICU's: \p{White_Space}.) U+200B separates too:
    /// the Mac's tokenizer then splits words on CharacterSet.whitespaces, which has it.
    [GeneratedRegex(@"[^\s\u200B\p{P}\u0021-\u002F\u003A-\u0040\u005B-\u0060\u007B-\u007E]+|[\p{P}\u0021-\u002F\u003A-\u0040\u005B-\u0060\u007B-\u007E]")]
    private static partial Regex Words();

    [GeneratedRegex(@"\[(?:PAD|UNK|CLS|SEP|MASK)\]")]
    private static partial Regex SpecialToken();
}
