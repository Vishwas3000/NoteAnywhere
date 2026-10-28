import SwiftUI

/// One note in the shared editor, under its source chip; website notes open their page in Safari.
struct NoteDetailView: View {
    let noteID: String
    @ObservedObject private var model = NotesModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var linked: String?  // a note:// link tapped in the editor
    @State private var confirmDelete = false

    var body: some View {
        if let note = model.note(noteID) {
            VStack(spacing: 6) {
                if note.hasSource { chip(note).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
                Text(note.edited.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if note.locked || NoteLock.isEnvelope(note.text) {
                    // The text is an encrypted envelope: editing it here would destroy the note.
                    // shortcut: no unlock on the phone yet; add it with the Mac's unlock UI (NoteLock has the core).
                    ContentUnavailableView("This Note Is Locked", systemImage: "lock.fill",
                                           description: Text("Open it on your Mac to read or edit it."))
                } else {
                    NoteEditor(noteID: noteID) { linked = $0 }
                }
            }
            .padding(.top, 4)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !note.locked { ShareLink(item: note.text) }
                    Menu {
                        if let url = note.pageURL {
                            Link(destination: url) { Label("Open Page", systemImage: "safari") }
                            Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
                            Divider()
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Note", systemImage: "trash") }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .navigationDestination(item: $linked) { NoteDetailView(noteID: $0) }
            .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Note", role: .destructive) {
                    model.delete(noteID)
                    dismiss()
                }
            } message: {
                Text(note.text.isEmpty ? "This empty note will be removed." : "“\(note.title)” will be removed.")
            }
        } else {
            ContentUnavailableView("Note Deleted", systemImage: "trash", description: Text("This note was deleted, maybe on another device."))
        }
    }

    @ViewBuilder
    private func chip(_ note: Note) -> some View {
        let label = HStack(spacing: 6) {
            NoteIcon(note: note, size: 16)
            Text(note.place).lineLimit(1)
            if note.pageURL != nil { Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold)).accessibilityHidden(true) }
        }
        .font(.footnote)
        .foregroundStyle(Color.secondary)  // not the link tint
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemFill), in: Capsule())

        if let url = note.pageURL {
            Link(destination: url) { label }
                .accessibilityLabel("Open \(note.place) in Safari")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }
}
