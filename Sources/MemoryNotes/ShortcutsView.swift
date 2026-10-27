import SwiftUI

/// Help ▸ Keyboard Shortcuts: the app's own shortcuts plus every editor shortcut and Markdown trigger.
/// The editor list comes from editor/shortcuts.json, the same source the browser overlay's "?" panel uses.
struct ShortcutsView: View {
    private struct Shortcut: Decodable, Hashable {
        let keys: String
        let action: String
        var group: String?
    }

    private static let app: [Shortcut] = [
        .init(keys: "⌥⇧Space", action: "Search all notes from anywhere", group: "App"),
        .init(keys: "⌘N", action: "New website note", group: "App"),
        .init(keys: "⌘F", action: "Find notes", group: "App"),
        .init(keys: "⌘1 / ⌘2", action: "Show Notes / Calendar", group: "App"),
        .init(keys: "⌘⌫", action: "Delete the selected note", group: "App"),
        .init(keys: "⌘← / ⌘T / ⌘→", action: "Calendar: previous / today / next", group: "App"),
        .init(keys: "⌥⇧N", action: "Browser: show or hide the page's notes", group: "App"),
    ]

    private static let editor: [Shortcut] = {
        guard let url = NoteEditor.editorDir?.appendingPathComponent("shortcuts.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Shortcut].self, from: data)) ?? []
    }()

    var body: some View {
        let all = Self.app + Self.editor
        let groups = all.reduce(into: [String]()) { if !$0.contains($1.group ?? "Editor") { $0.append($1.group ?? "Editor") } }
        List {
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(all.filter { ($0.group ?? "Editor") == group }, id: \.self) { shortcut in
                        LabeledContent(shortcut.action) {
                            Text(shortcut.keys).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if Self.editor.isEmpty {
                Text("Editor shortcuts appear here once the editor is installed.").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}
