#if DEBUG
import Foundation

/// Launch with -seedSampleNotes to try the app (and take screenshots) in the simulator. Only fills an empty database.
enum SampleNotes {
    static func seed() {
        guard NoteStore.loadAll().isEmpty else { return }
        let next = "B0000000-0000-4000-8000-000000000002", glass = "B0000000-0000-4000-8000-000000000003"
        // id, kind, target, label, then each saved version as (days ago, Markdown); every version leaves a calendar entry.
        let samples: [(String, Note.Kind, String, String, [(Double, String)])] = [
            ("B0000000-0000-4000-8000-000000000001", .app, "com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)", "Slack", [
                (1.2, "# 1:1 with Alex\n- [ ] Share the sync design"),
                (0.05, "# 1:1 with Alex\n- [x] Share the sync design\n- [ ] Ask about the Supabase budget\n- [ ] Demo the iPhone app"),
            ]),
            (next, .url, "github.com/vercel/next.js", "GitHub - vercel/next.js: The React Framework", [
                (3, "# Next.js caching\n`use cache` replaces unstable_cache."),
                (0.1, "# Next.js caching\n`use cache` replaces unstable_cache. Tags revalidate on demand with **updateTag**.\n\n- Partial prerendering is on by default\n- Compare with [Liquid Glass ideas](note://\(glass))"),
            ]),
            ("B0000000-0000-4000-8000-000000000004", .url, "", "", [
                (0.2, "# Groceries\n- [ ] Oat milk\n- [ ] Coffee beans\n- [x] Bananas\n- [ ] Basil"),
            ]),
            ("B0000000-0000-4000-8000-000000000005", .app, "com.figma.Desktop/MemoryNotes iOS", "Figma", [
                (1.1, "# Design review\nTab bar: Notes, Calendar, Graph, Settings. Source chip above the editor; yellow accent only for state."),
            ]),
            (glass, .url, "developer.apple.com/design/human-interface-guidelines/materials", "Materials | Apple Developer Documentation", [
                (5, "# Liquid Glass ideas\nGlass for the floating layer only."),
                (2, "# Liquid Glass ideas\nGlass for the floating layer only: toolbars, tab bars, the overlay panel. Content stays opaque.\n\n> Don't stack glass on glass."),
            ]),
            ("B0000000-0000-4000-8000-000000000006", .url, "github.com/jkrukowski/swift-embeddings", "jkrukowski/swift-embeddings", [
                (3.2, "# MiniLM on iOS\nMLTensor needs iOS 18. The model is 90 MB, so download it on the first search, not at launch."),
            ]),
            ("B0000000-0000-4000-8000-000000000007", .url, "chatgpt.com/c/68f1a2", "Whisper STT Explained", [
                (9, "# Whisper speech to text\nLog-Mel spectrogram in, tokens out. `large-v3` for accuracy, `small` on device."),
            ]),
            ("B0000000-0000-4000-8000-000000000008", .app, "com.apple.dt.Xcode/memoryNotes", "Xcode", [
                (14, "# Release checklist\n- [ ] Bump the build number\n- [ ] Archive and upload\n- [ ] Write the release notes"),
                (12, "# Release checklist\n- [x] Bump the build number\n- [ ] Archive and upload\n- [ ] Write the release notes"),
            ]),
            ("B0000000-0000-4000-8000-000000000009", .url, "en.wikipedia.org/wiki/Fourier_transform", "Fourier transform - Wikipedia", [
                (20, "# Fourier transform\nAny signal is a sum of sines. The FFT does it in n log n."),
            ]),
            ("B0000000-0000-4000-8000-00000000000A", .url, "", "", [
                (40, "# Trip to Goa\nFlights on the 14th. Book the scooter in Anjuna."),
            ]),
        ]
        let now = Date().timeIntervalSince1970 * 1000, day = 86_400_000.0
        for (id, kind, target, label, versions) in samples {
            let created = now - versions[0].0 * day
            for (ago, text) in versions {
                try? NoteStore.save(Note(id: id, kind: kind, target: target, label: label, text: text,
                                         createdAt: created, updatedAt: now - ago * day))
            }
        }
    }
}
#endif
