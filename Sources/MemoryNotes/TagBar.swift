import SwiftUI

/// Under a note's source: its #tags as chips, "+ Tag" offering the tags already in use, and the notes that share a tag
/// (D77). The chips only edit the note's "#tag" text (D32), so tags sync and show everywhere as before.
struct TagBar: View {
    let note: Note
    /// Where a related note opens (the main window: its side peek) and how a tag's notes are listed (a search).
    let open: (String) -> Void
    let search: (String) -> Void
    @ObservedObject private var model = NotesModel.shared
    @State private var adding = false
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let tags = note.tags
        let related = Note.related(to: note, in: model.notes)
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { chip($0) }
            Button { adding = true } label: { Label("Tag", systemImage: "plus") }
                .buttonStyle(.borderless)
                .help("Add a tag, such as the project this note is about")
                .popover(isPresented: $adding, arrowEdge: .bottom) { picker(skipping: tags) }
            Spacer(minLength: 0)
            if !related.isEmpty {
                Menu {
                    ForEach(related, id: \.note.id) { item in
                        Button(item.note.title + "   " + item.shared.map { "#" + $0 }.joined(separator: " ")) { open(item.note.id) }
                    }
                } label: {
                    Label(related.count == 1 ? "1 related note" : "\(related.count) related notes", systemImage: "link")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Notes that share a tag with this one")
            }
        }
        .font(.callout)
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Button("#" + tag) { search(tag) }
                .buttonStyle(.plain)
                .help("Show every note tagged #\(tag)")
            Button { write(Note.removing(tag: tag, from: text)) } label: { Image(systemName: "xmark").imageScale(.small) }
                .buttonStyle(.plain)
                .help("Remove #\(tag) from this note")
                .accessibilityLabel("Remove #\(tag)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(Color.notesAccent)
        .background(Color.notesAccent.opacity(0.14), in: Capsule())
    }

    /// The tags in use, most used first, narrowed by what's typed; Return adds exactly what's typed, new or not.
    private func picker(skipping current: [String]) -> some View {
        let counts = model.notes.flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let query = String(typed.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }).lowercased()
        let matches = counts.keys.filter { !current.contains($0) && (query.isEmpty || $0.contains(query)) }
            .sorted { (counts[$1, default: 0], $0) < (counts[$0, default: 0], $1) }
            .prefix(8)
        let name = Note.tagName(typed)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Tag", text: $typed, prompt: Text("Project or topic, e.g. noteanywhere"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { add(name) }
            if let name, counts[name] == nil, !current.contains(name) {
                Button("Add new tag #\(name)") { add(name) }
            } else if !typed.isEmpty, name == nil {
                Text("A tag needs a letter.").foregroundStyle(.secondary)
            }
            ForEach(Array(matches), id: \.self) { tag in
                Button { add(tag) } label: {
                    LabeledContent("#" + tag) { Text("\(counts[tag, default: 0])").monospacedDigit().foregroundStyle(.secondary) }
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(width: 280)
        .onAppear { typed = ""; fieldFocused = true }
    }

    /// The note's current text (it may have changed since this view was drawn).
    private var text: String { model.textBinding(note.id).wrappedValue }

    private func add(_ tag: String?) {
        guard let tag else { return }
        write(Note.adding(tag: tag, to: text))
        adding = false
    }

    /// The same path as typing: saved with the edit time, a snapshot and the sync flag, and shown in the editor.
    private func write(_ newText: String) {
        guard newText != text else { return }
        model.textBinding(note.id).wrappedValue = newText
    }
}
