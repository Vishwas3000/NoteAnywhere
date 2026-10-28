import AppKit
import SwiftUI

enum WindowMode: String, CaseIterable { case notes = "Notes", calendar = "Calendar", graph = "Graph" }

/// What the menu commands can do in the focused notes window.
struct WindowActions {
    var newNote: () -> Void
    var newWebsiteNote: () -> Void
    var findNotes: () -> Void
    var show: (WindowMode) -> Void
    var deleteSelected: (() -> Void)?
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

/// Every note in one place: a sidebar of app and website notes (including ones written in the browser),
/// with the selected note or the calendar on the right.
struct NotesWindow: View {
    @ObservedObject private var model = NotesModel.shared
    @AppStorage("windowMode") private var mode = WindowMode.notes
    @State private var selection: String?
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []
    @State private var searchedQuery = ""  // the query `hits` belong to, so "no results" never flashes mid-debounce
    @State private var searchFocused = false
    @State private var pendingDelete: Note?
    @State private var editingAddress = false  // shows the address field for a note that already has one
    @FocusState private var targetFocused: Bool
    @State private var folderFilter: String?  // nil: All Notes
    @State private var folderPrompt: FolderPrompt?
    @State private var folderName = ""
    @Environment(\.openWindow) private var openWindow

    /// "New Folder…" (optionally moving a note into it) or "Rename…".
    private struct FolderPrompt: Identifiable {
        var id = UUID()
        var moving: String?  // note to move into the new folder
        var renaming: Folder?
    }

    /// The notes in the selected folder (all of them in All Notes).
    private var visibleNotes: [Note] { model.notes.filter { folderFilter == nil || $0.folderID == folderFilter } }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch mode {
            case .calendar: CalendarView()
            case .graph: GraphView()
            case .notes: detail
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(WindowMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) { newNoteMenu }
            if mode == .notes, let note = selectedNote {
                ToolbarItem {
                    Button { pendingDelete = note } label: { Label("Delete Note", systemImage: "trash") }
                        .help("Delete Note")
                }
            }
        }
        .focusedSceneValue(\.windowActions, WindowActions(
            newNote: newNote,
            newWebsiteNote: newWebsiteNote,
            findNotes: { mode = .notes; searchFocused = true },
            show: { mode = $0 },
            deleteSelected: selectedNote.map { note in { pendingDelete = note } }
        ))
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { note in
            Button("Delete", role: .destructive) { delete(note) }
        } message: { note in
            Text(note.text.isEmpty ? "This empty note will be removed." : "“\(note.title)” will be removed.")
        }
        .tint(.notesAccent)
        .frame(minWidth: 760, minHeight: 480)
        .navigationSubtitle(searching ? "^[\(hits.count) result](inflect: true)" : "^[\(visibleNotes.count) note](inflect: true)")
    }

    private var selectedNote: Note? { selection.flatMap { id in model.notes.first { $0.id == id } } }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if searching {
                if !hits.isEmpty {
                    Section { ForEach(hits, id: \.note.id) { row($0.note) } } header: { sectionHeader("Results") }
                }
            } else {
                folderSection
                let shown = visibleNotes
                let pinned = shown.filter(\.pinned).sorted { $0.updatedAt > $1.updatedAt }
                if !pinned.isEmpty {
                    Section { ForEach(pinned) { row($0) } } header: { sectionHeader("Pinned") }
                }
                ForEach(NoteDates.sections(shown.filter { !$0.pinned })) { section in
                    Section { ForEach(section.notes) { row($0) } } header: { sectionHeader(section.title) }
                }
                let tags = tagCounts
                if !tags.isEmpty {
                    Section {
                        ForEach(tags, id: \.tag) { item in
                            Button { query = "#" + item.tag } label: {
                                LabeledContent {
                                    Text("\(item.count)").monospacedDigit()
                                } label: {
                                    Label("#" + item.tag, systemImage: "number").foregroundStyle(Color.notesAccent)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows the notes with this tag")
                        }
                    } header: { sectionHeader("Tags") }
                }
            }
        }
        .overlay {
            if searching, searchedQuery == query, hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if !searching, model.notes.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "note.text",
                                       description: Text("Press ⌘N to write a note. Use + to tie one to a website or an app."))
            }
        }
        .searchable(text: $query, isPresented: $searchFocused, placement: .sidebar, prompt: "Search by meaning or keyword")
        .alert(folderPrompt?.renaming == nil ? "New Folder" : "Rename Folder", isPresented: Binding(
            get: { folderPrompt != nil }, set: { if !$0 { folderPrompt = nil } }
        ), presenting: folderPrompt) { prompt in
            TextField("Name", text: $folderName)
            Button(prompt.renaming == nil ? "Create" : "Rename") { finishFolderPrompt(prompt) }
                .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))  // debounce typing
            guard !Task.isCancelled else { return }
            hits = await model.search(query)
            searchedQuery = query
        }
        .onChange(of: model.openRequest, initial: true) { _, id in  // initial: a request made while the window was closed
            guard let id else { return }
            query = ""
            mode = .notes
            selection = id
            model.openRequest = nil
        }
        .onChange(of: model.searchRequest, initial: true) { _, request in
            guard let request else { return }
            mode = .notes
            query = request
            model.searchRequest = nil
        }
        .onChange(of: model.calendarRequest) { _, day in if day != nil { mode = .calendar } }  // CalendarView takes it from there
        .onChange(of: selection) { _, id in if id != nil { mode = .notes } }
        .navigationSplitViewColumnWidth(min: 240, ideal: 290)
    }

    /// Every #tag in use with its number of notes, most used first, like Obsidian's tag pane.
    private var tagCounts: [(tag: String, count: Int)] {
        let counts = model.notes.flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { (tag: $0.key, count: $0.value) }
    }

    /// Bold, sentence-case headers like Notes, instead of the sidebar's small grey ones.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.primary).textCase(nil).padding(.top, 4)
    }

    private func row(_ note: Note) -> some View {
        NoteRow(note: note, date: NoteDates.short(note.edited))
            .tag(note.id)
            .contextMenu { noteMenu(note) }
    }

    /// Apple Notes' note menu, plus colour labels like Chrome's tab groups.
    @ViewBuilder
    private func noteMenu(_ note: Note) -> some View {
        Button { openWindow(id: "note", value: note.id) } label: { Label("Open Note in New Window", systemImage: "macwindow.badge.plus") }
        Divider()
        Button { model.update(note.id) { $0.pinned.toggle() } } label: {
            Label(note.pinned ? "Unpin Note" : "Pin Note", systemImage: note.pinned ? "pin.slash" : "pin")
        }
        Divider()
        Button(action: newNote) { Label("New Note", systemImage: "square.and.pencil") }
        Button { selection = model.duplicate(note).id } label: { Label("Duplicate Note", systemImage: "plus.square.on.square") }
            .disabled(note.locked)
        Divider()
        ShareLink(item: note.text, subject: Text(note.title), preview: SharePreview(note.title)) {
            Label("Share Note", systemImage: "square.and.arrow.up")
        }
        .disabled(note.locked)
        Divider()
        Menu {
            Button("All Notes (No Folder)") { model.update(note.id) { $0.folderID = nil } }.disabled(note.folderID == nil)
            if !model.folders.isEmpty { Divider() }
            ForEach(model.folders) { folder in
                Button(folder.name) { model.update(note.id) { $0.folderID = folder.id } }.disabled(note.folderID == folder.id)
            }
            Divider()
            Button("New Folder…") { promptFolder(moving: note.id) }
        } label: { Label("Move to", systemImage: "folder") }
        Menu {
            Button("None") { model.update(note.id) { $0.color = nil } }.disabled(note.color == nil)
            Divider()
            ForEach(NoteColor.allCases, id: \.self) { color in
                Button { model.update(note.id) { $0.color = color } } label: {
                    Label { Text(color.title) } icon: { Image(nsImage: Self.dot(color)) }
                }
                .disabled(note.color == color)
            }
        } label: { Label("Color", systemImage: "circle.lefthalf.filled") }
        if let url = pageURL(note) {
            Divider()
            pageActions(url)
        }
        Divider()
        Button(role: .destructive) { pendingDelete = note } label: { Label("Delete", systemImage: "trash") }
    }

    /// Menus draw images as-is but tint SF Symbols, so colour swatches go in as plain images.
    private static func dot(_ color: NoteColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color.swatch).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Folders

    @ViewBuilder
    private var folderSection: some View {
        Section {
            folderRow(nil, name: "All Notes", count: model.notes.count)
            ForEach(model.folders) { folder in
                folderRow(folder, name: folder.name, count: model.notes.filter { $0.folderID == folder.id }.count)
                    .contextMenu {
                        Button("Rename…") { folderName = folder.name; folderPrompt = FolderPrompt(renaming: folder) }
                        Button("Delete Folder", role: .destructive) {
                            if folderFilter == folder.id { folderFilter = nil }
                            model.deleteFolder(folder.id)
                        }
                    }
            }
            Button { promptFolder(moving: nil) } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        } header: { sectionHeader("Folders") }
    }

    private func folderRow(_ folder: Folder?, name: String, count: Int) -> some View {
        let current = folderFilter == folder?.id
        return Button { folderFilter = folder?.id } label: {
            LabeledContent {
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            } label: {
                Label(name, systemImage: folder == nil ? "tray.full" : "folder")
                    .fontWeight(current ? .semibold : .regular)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(current ? AnyShapeStyle(Color.notesAccent.opacity(0.18)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityHint(folder == nil ? "Shows every note" : "Shows the notes in this folder")
    }

    private func promptFolder(moving noteID: String?) {
        folderName = ""
        folderPrompt = FolderPrompt(moving: noteID)
    }

    private func finishFolderPrompt(_ prompt: FolderPrompt) {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let folder = prompt.renaming {
            model.renameFolder(folder.id, to: name)
        } else {
            let folder = model.addFolder(name)
            if let id = prompt.moving { model.update(id) { $0.folderID = folder.id } }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let note = selectedNote {
            VStack(alignment: .leading, spacing: 10) {
                header(note)
                Text("Edited \(note.edited.formatted(date: .long, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                NoteEditor(noteID: note.id, fontSize: 15, titleLine: true, focusIfEmpty: !editingAddress)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: targetFocused) { _, focused in editingAddress = focused }
        } else {
            ContentUnavailableView("No Note Selected", systemImage: "note.text",
                                   description: Text("Pick a note in the sidebar, or press ⌘N to start one."))
        }
    }

    /// The source chip; for a note without one, a quiet "Add Website" button; the address field while editing it.
    @ViewBuilder
    private func header(_ note: Note) -> some View {
        if note.kind == .url && editingAddress {
            TextField("Page address, e.g. github.com/vercel/next.js", text: targetBinding(note.id))
                .textFieldStyle(.roundedBorder)
                .focused($targetFocused)
                .task(id: note.id) { if editingAddress { targetFocused = true } }
                .onSubmit { targetFocused = false }
                .onExitCommand { targetFocused = false }
        } else if let url = pageURL(note) {
            HStack(spacing: 4) {
                Button { NSWorkspace.shared.open(url) } label: { chip(note) }
                    .buttonStyle(.plain)
                    .help("Open \(url.absoluteString)")
                    .contextMenu { pageActions(url) }
                Menu {
                    pageActions(url)
                    Divider()
                    Button("Edit Address…") { editingAddress = true }
                    Button("Remove Website") { model.binding(note.id, \.target).wrappedValue = "" }
                } label: {
                    Label("Page Actions", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open Page, Copy Link, Edit Address")
            }
        } else if note.hasSource {
            chip(note)
        } else {
            Button { editingAddress = true } label: { Label("Add Website", systemImage: "link.badge.plus") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Tie this note to a web page, so it shows up there in the browser")
        }
    }

    private func chip(_ note: Note) -> some View {
        HStack(spacing: 6) {
            NoteIcon(note: note, size: 16)
            Text(note.place).lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quinary, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func pageActions(_ url: URL) -> some View {
        Button("Open Page") { NSWorkspace.shared.open(url) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    private func pageURL(_ note: Note) -> URL? {
        note.kind == .url && !note.target.isEmpty ? URL(string: "https://\(note.target)") : nil
    }

    // MARK: Actions

    private var newNoteMenu: some View {
        Menu {
            Button("New Note", action: newNote)
            Button("New Note for Website", action: newWebsiteNote)
            Menu("New Note for App") {
                ForEach(runningApps(), id: \.processIdentifier) { app in
                    Button {
                        selection = model.add(kind: .app, target: app.bundleIdentifier!, label: app.localizedName ?? "").id
                    } label: {
                        Label { Text(app.localizedName ?? "") } icon: { Image(nsImage: smallIcon(app)) }
                    }
                }
            }
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        } primaryAction: {
            newNote()
        }
        .help("New Note")
    }

    /// A note on its own; the editor takes the focus (see EditorView) so you can type right away.
    private func newNote() {
        mode = .notes
        query = ""
        editingAddress = false
        selection = model.add(kind: .url, target: "", label: "", folderID: folderFilter).id  // in the folder you're looking at
    }

    private func newWebsiteNote() {
        newNote()
        editingAddress = true  // keeps the field up once the first typed character makes the target non-empty
    }

    private func delete(_ note: Note) {
        if selection == note.id { selection = nil }
        model.delete(note.id)
    }

    /// Accepts pasted URLs: strips the scheme, "www." and a trailing "/" so the target matches what the extension sends.
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

    private func smallIcon(_ app: NSRunningApplication) -> NSImage {
        let icon = (app.icon?.copy() as? NSImage) ?? NSImage()  // copy: NSRunningApplication shares its icon instance
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// An Apple Notes list row: bold title; the date then the preview; the app or site it belongs to.
struct NoteRow: View {
    let note: Note
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let color = note.color {
                    Circle().fill(color.swatch).frame(width: 8, height: 8).accessibilityLabel("\(color.title) label")
                }
                if note.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                Text(note.title).font(.headline).lineLimit(1)
            }
            (Text(date) + Text("  ") + Text(note.preview.isEmpty ? "No additional text" : note.preview).foregroundStyle(.secondary))
                .font(.subheadline)
                .lineLimit(1)
            if note.hasSource {
                HStack(spacing: 4) {
                    NoteIcon(note: note, size: 12)
                    Text(note.shortSource).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

extension Note {
    /// "Slack · Alex Rivera (DM)" or "chatgpt.com": the app with its narrowest place, or the site's host.
    var shortSource: String {
        if kind == .url { return String(target.prefix { $0 != "/" }) }
        let parts = target.split(separator: "/")
        return parts.count > 1 ? "\(label) · \(parts.last!)" : label
    }
}

/// Apple Notes' date wording; `now` and `calendar` are parameters so tests can pin them.
enum NoteDates {
    struct Section: Identifiable {
        let title: String
        var notes: [Note]
        var id: String { title }
    }

    /// Sidebar sections, newest edit first: Today, Yesterday, Previous 7 Days, Previous 30 Days, then "October 2026".
    static func sections(_ notes: [Note], now: Date = .now, calendar: Calendar = .current) -> [Section] {
        var sections: [Section] = []
        for note in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let title = switch days(note.edited, before: now, calendar) {
            case ...0: "Today"
            case 1: "Yesterday"
            case ...7: "Previous 7 Days"
            case ...30: "Previous 30 Days"
            default: note.edited.formatted(style(calendar).month(.wide).year())
            }
            if sections.last?.title == title {
                sections[sections.count - 1].notes.append(note)
            } else {
                sections.append(Section(title: title, notes: [note]))
            }
        }
        return sections
    }

    /// A row's date: the time today, the weekday within the past week, otherwise a short date.
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        switch days(date, before: now, calendar) {
        case ...0: date.formatted(style(calendar).hour().minute())
        case ...6: date.formatted(style(calendar).weekday(.wide))
        default: date.formatted(style(calendar).day().month(.defaultDigits).year(.twoDigits))
        }
    }

    /// Calendar days between the two dates; edits from the future (clock changes) count as today.
    private static func days(_ date: Date, before now: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    private static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }
}

/// One note in its own window ("Open Note in New Window").
struct NoteWindow: View {
    let noteID: String
    @ObservedObject private var model = NotesModel.shared

    var body: some View {
        if let note = model.notes.first(where: { $0.id == noteID }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Edited \(note.edited.formatted(date: .long, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                NoteEditor(noteID: note.id, fontSize: 15, titleLine: true)
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(note.title)
            .tint(.notesAccent)
        } else {
            ContentUnavailableView("Note Deleted", systemImage: "trash", description: Text("This note no longer exists."))
        }
    }
}
