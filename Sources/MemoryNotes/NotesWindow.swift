import AppKit
import SwiftUI

/// Every note in one place: app notes and website notes (including ones written in the browser).
struct NotesWindow: View {
    @ObservedObject private var model = NotesModel.shared
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Apps") {
                    ForEach(model.notes.filter { $0.kind == .app }) { row($0, title: $0.label) }
                }
                Section("Websites") {
                    ForEach(model.notes.filter { $0.kind == .url }) { row($0, title: $0.target) }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                Menu {
                    ForEach(runningApps(), id: \.processIdentifier) { app in
                        Button(app.localizedName ?? "") {
                            selection = model.add(kind: .app, target: app.bundleIdentifier!, label: app.localizedName ?? "").id
                        }
                    }
                } label: { Label("New App Note", systemImage: "app.badge") }
                Button {
                    selection = model.add(kind: .url, target: "example.com", label: "").id
                } label: { Label("New Website Note", systemImage: "globe") }
            }
        } detail: {
            if let id = selection, let note = model.notes.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 8) {
                    if note.kind == .url {
                        TextField("Site or page, e.g. github.com or github.com/vercel/next.js", text: targetBinding(id))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Text("\(note.label) — \(note.target)").foregroundStyle(.secondary)
                    }
                    TextEditor(text: model.binding(id, \.text)).font(.body)
                    HStack {
                        Spacer()
                        Button("Delete Note", role: .destructive) {
                            selection = nil
                            model.delete(id)
                        }
                    }
                }
                .padding()
            } else {
                Text("Select or create a note").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    private func row(_ note: Note, title: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(note.text.split(separator: "\n").first.map(String.init) ?? "Empty note").lineLimit(1)
        }
        .tag(note.id)
    }

    /// Accepts pasted URLs: strips the scheme and "www." so the target matches what the extension sends.
    private func targetBinding(_ id: String) -> Binding<String> {
        let raw = model.binding(id, \.target)
        return Binding(get: { raw.wrappedValue }, set: { value in
            raw.wrappedValue = value.replacing(#/^https?:\/\//#, with: "").replacing(#/^www\./#, with: "")
        })
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}
