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
                if !note.target.isEmpty { chip(note).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
                Text(note.edited.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NoteEditor(noteID: noteID) { linked = $0 }
            }
            .padding(.top, 4)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: note.text)
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
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())

        if let url = note.pageURL {
            Link(destination: url) { label }
                .accessibilityLabel("Open \(note.place) in Safari")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }
}
