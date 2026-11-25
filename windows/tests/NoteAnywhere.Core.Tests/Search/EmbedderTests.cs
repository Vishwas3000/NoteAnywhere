using System.Runtime.InteropServices;
using System.Security.Cryptography;
using NoteAnywhere.Core.Search;

namespace NoteAnywhere.Core.Tests.Search;

/// Needs the search model, downloaded once (~90 MB) into the temp folder: runs only with NOTEANYWHERE_MODEL_TESTS=1,
/// so quick runs and CI stay offline.
sealed class ModelFactAttribute : FactAttribute
{
    public ModelFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("NOTEANYWHERE_MODEL_TESTS") != "1")
            Skip = "Downloads the search model: set NOTEANYWHERE_MODEL_TESTS=1 to run it.";
    }
}

public class EmbedderTests
{
    // Kept between runs, unlike AppPaths.Data, so the model downloads once.
    static readonly string Models = Path.Combine(Path.GetTempPath(), "noteanywhere-model");

    static async Task<Embedder> Model()
    {
        var embedder = new Embedder(Models);
        Assert.NotNull(await embedder.EmbedAsync("download it, if it isn't here yet"));
        return embedder;
    }

    static readonly string LongNote = "Planning notes\n" + string.Join(" ", Enumerable.Range(1, 30)
        .Select(i => $"Week {i}: review the budget, the hiring plan and the launch checklist with the team."));

    /// The Mac's vectors for four texts, as Float32 little-endian in base64. Made on 2026-11-25 on the developer's Mac
    /// (macOS 26, arm64) by an 18-line Swift program doing what SearchIndex.embed does — Bert.loadModelBundle(from:) on
    /// the app's own download of the model (commit 1110a24, the one Embedder pins), maxLength 256,
    /// .meanPool(normalize: true), encode, Float scalars — compiled against the app's debug build of swift-embeddings
    /// 0.1.1 (47d2f40, as Package.resolved pins it). Their first values: -0.0811438, -0.00164225, 0.0284478 …;
    /// 0.0439336, 0.0589344, 0.0481784 …; 0.0668837, 0.0207628, 0.0633766 …; -0.0422337, 0.0467636, -0.0206673 ….
    /// This code's cosine with each was 1.0000000020, 0.9999999944, 0.9999999856 and 0.9999999365.
    static readonly (string Text, string Mac)[] MacVectors =
    [
        ("GitHub github.com/vercel/next.js\nRouting notes\n- [ ] Read the app router docs #nextjs\nServer components render first, then the client hydrates.",
            "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"),
        ("The quick brown fox jumps over the lazy dog.",
            "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"),
        ("Café crème brûlée: €4.50 (naïve résumé) 👍 東京 = 1+1 <ok> | ~done~",
            "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"),
        (LongNote,
            "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"),
    ];

    [ModelFact]
    public async Task VectorsMatchTheMacs()
    {
        using var embedder = await Model();
        foreach (var (text, mac) in MacVectors)
        {
            var expected = MemoryMarshal.Cast<byte, float>(Convert.FromBase64String(mac)).ToArray();
            var actual = (await embedder.EmbedAsync(text))!;
            Assert.Equal(384, actual.Length);
            var cosine = expected.Zip(actual).Sum(p => (double)p.First * p.Second);  // both are unit vectors
            Assert.True(cosine >= 0.999, $"cosine {cosine} with the Mac's vector for {text[..20]}…");
            Assert.Equal(1, Math.Sqrt(actual.Sum(x => (double)x * x)), 5);
        }
    }

    /// Token ids from the same Swift program: the cases where ML.Tokenizers' own BERT pipeline would differ from the Mac's.
    [ModelFact]
    public async Task TokensMatchTheMacs()
    {
        using var embedder = await Model();
        var tokenizer = Embedder.CreateTokenizer(Path.Combine(Models, "vocab.txt"));
        (string Text, long[] Mac)[] cases =
        [
            ("Hello\tWorld\r\nNew line\fform feed", [101, 7592, 2088, 2047, 2240, 2433, 5438, 102]),
            ("[CLS] literal [SEP] and [MASK] and [cls]", [101, 101, 18204, 102, 1998, 103, 1998, 1031, 18856, 2015, 1033, 102]),
            ("한국어 텍스트", [101, 1469, 30006, 30021, 29991, 30014, 30020, 29999, 30008, 1467, 30009, 30020, 29997, 30017, 30003, 30017, 102]),
            ("Code: `let x = a[i] ^ b | c ~ d`; $HOME; 50% off; x<y>z",
                [101, 3642, 1024, 1036, 2292, 1060, 1027, 1037, 1031, 1045, 1033, 1034, 1038, 1064, 1039, 1066, 1040, 1036, 1025,
                 1002, 2188, 1025, 2753, 1003, 2125, 1025, 1060, 1026, 1061, 1028, 1062, 102]),
            ("Control\u0001char nul\u0000 vt\u000bhere nel\u0085here nbsp\u00a0here zero\u200bwidth",
                [101, 100, 100, 28879, 2182, 11265, 2140, 2182, 1050, 5910, 2361, 2182, 5717, 9381, 102]),
        ];
        foreach (var (text, mac) in cases) Assert.Equal(mac, Embedder.TokenIds(tokenizer, text));
        // A long note keeps its first 256 tokens and loses its [SEP], as on the Mac.
        Assert.Equal([3319, 1996, 5166], Embedder.TokenIds(tokenizer, LongNote)[^3..]);
        Assert.Equal(256, Embedder.TokenIds(tokenizer, LongNote).Length);
    }

    [ModelFact]
    public async Task SearchFindsANoteByMeaningAlone()
    {
        using var embedder = await Model();
        var connection = SearchIndexTests.NewDatabase("dog", "tax", "pasta");
        TestNote[] notes =
        [
            new("dog", "Walked the dog in the park this morning; she chased a squirrel."),
            new("tax", "Quarterly tax return: gather the invoices and receipts."),
            new("pasta", "Pasta: garlic, olive oil and chili flakes."),
        ];
        var index = new SearchIndex(connection, embedder.EmbedAsync);
        await index.UpdateAsync(notes);
        var rows = SearchIndexTests.Rows(connection);
        Assert.Equal(["dog", "pasta", "tax"], rows.Select(r => r.Id));
        Assert.All(rows, row => Assert.Equal(384, row.Vector.Length));
        var hits = await index.SearchAsync("dinner ideas", notes);  // no word in common with any note
        Assert.Equal(["pasta"], hits.Select(h => h.Note.Id));
        Assert.InRange(hits[0].Score, 0.3, 0.5);
    }

    [ModelFact]
    public async Task ADownloadIsKeptOnlyIfItsHashMatches()
    {
        var folder = Path.Combine(AppPaths.Data, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var (_, url, sha256) = Embedder.Files.Single(f => f.Name == "vocab.txt");
        var good = Path.Combine(folder, "vocab.txt");
        await Embedder.DownloadAsync(url, good, sha256);
        Assert.Equal(sha256, Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(good))));

        var bad = Path.Combine(folder, "tampered.txt");
        await Assert.ThrowsAsync<InvalidDataException>(() => Embedder.DownloadAsync(url, bad, new string('0', 64)));
        Assert.Equal([good], Directory.GetFiles(folder));  // nothing kept, no temporary file left
    }
}
