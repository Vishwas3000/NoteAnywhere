import SwiftUI

/// A note's actions, like the Mac's right-click menu: for the list's long press and the note's More button.
struct NoteMenu: View {
    let note: Note
    let delete: () -> Void
    @ObservedObject private var model = NotesModel.shared

    var body: some View {
        Button { model.update(note.id) { $0.pinned.toggle() } } label: {
            Label(note.pinned ? "Unpin Note" : "Pin Note", systemImage: note.pinned ? "pin.slash" : "pin")
        }
        Menu {
            Button("All Notes (No Folder)") { model.update(note.id) { $0.folderID = nil } }.disabled(note.folderID == nil)
            ForEach(model.folders) { folder in
                Button(folder.name) { model.update(note.id) { $0.folderID = folder.id } }.disabled(note.folderID == folder.id)
            }
            Button { model.newFolderFor = note.id } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
        } label: { Label("Move to", systemImage: "folder") }
        Menu {
            Button("None") { model.update(note.id) { $0.color = nil } }.disabled(note.color == nil)
            ForEach(NoteColor.allCases, id: \.self) { color in
                Button { model.update(note.id) { $0.color = color } } label: {
                    Label { Text(color.title) } icon: { Self.dot(color) }
                }
                .disabled(note.color == color)
            }
        } label: { Label("Color", systemImage: "circle.lefthalf.filled") }
        if !note.locked {
            Button { model.duplicate(note) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            ShareLink(item: note.text) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        if let url = note.pageURL {
            Link(destination: url) { Label("Open Page", systemImage: "safari") }
            Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
        }
        Divider()
        Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
    }

    /// Menus draw symbols in one color unless the image is pre-tinted.
    static func dot(_ color: NoteColor) -> Image {
        Image(uiImage: UIImage(systemName: "circle.fill")!.withTintColor(UIColor(color.swatch), renderingMode: .alwaysOriginal))
    }
}
