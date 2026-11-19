import SwiftUI

/// The inspector beside a note (⌥⌘I, D77): its #tags, a field to add one, and the notes that share a tag. Tags stay
/// "#tag" text in the note (D32): this edits that text the way typing does, so tags sync and show everywhere as before.
struct NoteInspector: View {
    let note: Note
    /// A related note opens in the main view; a tag lists its notes (a search).
    let open: (String) -> Void
    let search: (String) -> Void
    @ObservedObject private var model = NotesModel.shared
    @State private var typed = ""

    var body: some View {
        let tags = note.tags
        let related = Note.related(to: note, in: model.notes)
        Form {
            Section {
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Button("#" + tag) { search(tag) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.notesAccent)
                            .help("Show every note tagged #\(tag)")
                        Spacer()
                        Button { write(Note.removing(tag: tag, from: text)) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove #\(tag) from this note")
                            .accessibilityLabel("Remove #\(tag)")
                    }
                }
                // A placeholder keeps the field visible (an empty form field shows nothing on the Mac). Return reads the
                // field itself: a value worked out when the view was drawn can miss the last letter typed.
                TextField("Add a tag", text: $typed, prompt: Text("Add a tag, e.g. noteanywhere"))
                    .labelsHidden()
                    .onSubmit { add(Note.tagName(typed)) }
                ForEach(suggestions(skipping: tags), id: \.self) { tag in
                    Button { add(tag) } label: { Label("#" + tag, systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
                if let hint { Text(hint).foregroundStyle(.secondary) }
            } header: {
                Text("Tags")
            } footer: {
                Text("You can also type # in the note.")
            }
            Section("Related Notes") {
                if related.isEmpty {
                    Text(tags.isEmpty ? "Tag this note to see the notes that share its tags." : "No other note has these tags yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(related, id: \.note.id) { item in
                    Button { open(item.note.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.note.title).lineLimit(1)
                            Text(item.shared.map { "#" + $0 }.joined(separator: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open “\(item.note.title)”")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Tags in use that contain what's typed: those starting with it first, then the most used.
    private func suggestions(skipping current: [String]) -> [String] {
        let query = String(typed.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }).lowercased()
        guard !query.isEmpty else { return [] }
        let counts = model.notes.flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.keys.filter { !current.contains($0) && $0.contains(query) }
            .sorted { ($0.hasPrefix(query) ? 0 : 1, -counts[$0, default: 0], $0) < ($1.hasPrefix(query) ? 0 : 1, -counts[$1, default: 0], $1) }
            .prefix(6).map { $0 }
    }

    /// What Return will do with what's typed, when that isn't obvious.
    private var hint: String? {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let name = Note.tagName(typed) else { return "A tag needs a letter." }
        return model.notes.contains { $0.tags.contains(name) } ? nil : "Return adds the new tag #\(name)."
    }

    /// The note's current text (it may have changed since this view was drawn).
    private var text: String { model.textBinding(note.id).wrappedValue }

    private func add(_ tag: String?) {
        guard let tag else { return }
        write(Note.adding(tag: tag, to: text))
        typed = ""
    }

    /// The same path as typing: saved with the edit time, a snapshot and the sync flag, and shown in the editor.
    private func write(_ newText: String) {
        guard newText != text else { return }
        model.textBinding(note.id).wrappedValue = newText
    }
}
