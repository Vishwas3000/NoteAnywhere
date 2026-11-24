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
    @AppStorage("welcomeShown") private var welcomeShown = false
    @AppStorage("inspectorShown") private var inspectorShown = false  // tags and related notes (D77)
    @State private var selection: String?
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []
    @State private var searchedQuery = ""  // the query `hits` belong to, so "no results" never flashes mid-debounce
    @State private var searchFocused = false
    @State private var pendingDelete: Note?
    @State private var editingAddress = false  // shows the address field for a note that already has one
    @FocusState private var targetFocused: Bool
    @State private var folderFilter: String?  // nil: All Notes
    @State private var starredOnly = false  // the "Starred" row: starred notes in any folder
    @State private var folderPrompt: FolderPrompt?
    @State private var folderName = ""
    @State private var lockPrompt: LockPrompt?
    @State private var peekID: String?  // a linked page open beside the note (side peek)
    @ObservedObject private var lockSession = LockSession.shared

    /// Locking a note may first need a notes password (first time) or unlocking (later).
    private enum LockPrompt: Identifiable {
        case setPassword(String), unlock(String)
        var id: String { switch self { case .setPassword(let id), .unlock(let id): id } }
    }
    @Environment(\.openWindow) private var openWindow

    /// "New Folder…" (optionally moving a note into it) or "Rename…".
    private struct FolderPrompt: Identifiable {
        var id = UUID()
        var moving: String?  // note to move into the new folder
        var renaming: Folder?
    }

    /// The notes in the selected folder (all of them in All Notes), or the starred ones.
    private var visibleNotes: [Note] {
        model.notes.filter { (folderFilter == nil || $0.folderID == folderFilter) && (!starredOnly || $0.starred) }
    }

    /// Every switch between Notes, Calendar and Graph comes through here, so Perf can time it.
    private func switchTo(_ new: WindowMode) {
        guard new != mode else { return }
        Perf.begin("\(mode.rawValue) → \(new.rawValue)")
        mode = new
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                switch mode {
                case .calendar: CalendarView().onAppear(perform: Perf.end)
                case .graph: GraphView().onAppear(perform: Perf.end)
                case .notes: detail.onAppear(perform: Perf.end)
                }
            }
            // The window decides the widths; this pane takes what the sidebar leaves and never pushes back. A minimum
            // from here gets the floating sidebar's width added on top, outgrows the window and a drag runs away (D80).
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Binding(get: { mode }, set: switchTo)) {
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
            if mode == .notes {
                ToolbarItem {
                    Button { inspectorShown.toggle() } label: { Label("Inspector", systemImage: "info.circle") }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(inspectorShown ? "Hide Inspector (⌥⌘I)" : "Show Inspector: tags and related notes (⌥⌘I)")
                }
            }
        }
        .toolbar(removing: .title)  // the app's name; the sidebar already shows the folder and its count
        .focusedSceneValue(\.windowActions, WindowActions(
            newNote: newNote,
            newWebsiteNote: newWebsiteNote,
            findNotes: { switchTo(.notes); searchFocused = true },
            show: switchTo,
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
        .onAppear {  // first launch: what Accessibility and the browser extension add
            guard !welcomeShown else { return }
            welcomeShown = true
            openWindow(id: "welcome")
        }
    }

    private var selectedNote: Note? { selection.flatMap { id in model.notes.first { $0.id == id } } }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if searching {
                if !hits.isEmpty {
                    Section { ForEach(hits, id: \.note.id) { row($0.note) } } header: {
                        sectionHeader(hits.count == 1 ? "1 Result" : "\(hits.count) Results")
                    }
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
        .hardScrollEdges()
        .bottomBar {  // Apple Notes' corner. The version is in About, Feedback in the Help menu (D84)
            HStack {
                Button { promptFolder(moving: nil) } label: { Label("New Folder", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .searchable(text: $query, isPresented: $searchFocused, placement: .sidebar, prompt: "Search by meaning or keyword")
        .sheet(item: $lockPrompt) { prompt in
            switch prompt {
            case .setPassword(let id):
                NotesPasswordSheet { set in
                    lockPrompt = nil
                    if set { model.lock(id) }
                }
            case .unlock:
                VStack {
                    LockedNoteView()
                    Button("Cancel") { lockPrompt = nil }.padding(.bottom)
                }
                .frame(width: 380, height: 300)
                .onChange(of: lockSession.isUnlocked) { _, open in
                    guard open, case .unlock(let id) = prompt, let note = model.notes.first(where: { $0.id == id }) else { return }
                    lockPrompt = nil
                    if note.locked { model.removeLock(id) } else { model.lock(id) }
                }
            }
        }
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
            let opened = model.notes.first { $0.id == id }
            if folderFilter != nil, opened?.folderID != folderFilter { folderFilter = nil }  // so its row shows too
            if starredOnly, opened?.starred != true { starredOnly = false }
            switchTo(.notes)
            selection = id
            model.focusRequest = model.canEdit(id) ? id : nil  // a locked note shows no editor to take it
            model.openRequest = nil
        }
        .onChange(of: model.searchRequest, initial: true) { _, request in
            guard let request else { return }
            switchTo(.notes)
            query = request
            model.searchRequest = nil
        }
        .onChange(of: model.calendarRequest) { _, day in if day != nil { switchTo(.calendar) } }  // CalendarView takes it from there
        .onChange(of: selection) { _, id in
            if id != nil { switchTo(.notes) }
            peekID = nil  // a peek belongs to the note it was opened from
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
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
        Button { model.update(note.id) { $0.starred.toggle() } } label: {
            Label(note.starred ? "Unstar Note" : "Star Note", systemImage: note.starred ? "star.slash" : "star")
        }
        if note.locked {
            Button { if lockSession.isUnlocked { model.removeLock(note.id) } else { lockPrompt = .unlock(note.id) } } label: {
                Label("Remove Lock", systemImage: "lock.open")
            }
        } else {
            Button { lockNote(note.id) } label: { Label("Lock Note", systemImage: "lock") }
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
        ColorLabelMenu(current: note.color) { color in model.update(note.id) { $0.color = color } }
        if let url = pageURL(note) {
            Divider()
            pageActions(url)
        } else if note.kind == .url {  // no page yet: tie it to one, so it shows up there in the browser
            Divider()
            Button { selection = note.id; editingAddress = true } label: { Label("Add Website…", systemImage: "link.badge.plus") }
        }
        Divider()
        Button(role: .destructive) { pendingDelete = note } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Folders

    @ViewBuilder
    private var folderSection: some View {
        Section {
            folderRow(nil, name: "All Notes", count: model.notes.count)
            starredRow
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
        } header: { sectionHeader("Folders") }
    }

    private var starredRow: some View {
        Button { folderFilter = nil; starredOnly = true } label: {
            LabeledContent {
                Text("\(model.notes.filter(\.starred).count)").monospacedDigit().foregroundStyle(.secondary)
            } label: {
                Label("Starred", systemImage: "star").fontWeight(starredOnly ? .semibold : .regular)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(starredOnly ? AnyShapeStyle(Color.notesAccent.opacity(0.18)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(starredOnly ? .isSelected : [])
        .accessibilityHint("Shows the starred notes")
    }

    private func folderRow(_ folder: Folder?, name: String, count: Int) -> some View {
        let current = !starredOnly && folderFilter == folder?.id
        return Button { folderFilter = folder?.id; starredOnly = false } label: {
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

    private func lockNote(_ id: String) {
        if !lockSession.hasPassword { lockPrompt = .setPassword(id) }
        else if lockSession.isUnlocked { model.lock(id) }
        else { lockPrompt = .unlock(id) }
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

    /// The inspector beside the note (⌥⌘I): its tags and the notes that share them (D77).
    @ViewBuilder
    private var inspector: some View {
        if let note = selectedNote, !note.locked {
            NoteInspector(note: note, open: { selection = $0 }, search: { query = "#" + $0 })
        } else if selectedNote != nil {
            ContentUnavailableView("Locked Note", systemImage: "lock", description: Text("Unlock it to see its tags."))
        } else {
            ContentUnavailableView("No Note Selected", systemImage: "note.text",
                                   description: Text("Select a note to see its tags and related notes."))
        }
    }

    /// Side by side as plain views, not split views: on macOS 26 each split view added the floating sidebar's width (and
    /// the inspector's) to the note's minimum once more, until it outgrew the window and a divider drag ran away (D80).
    /// The peek and the inspector have fixed widths; the note takes the rest.
    private var detail: some View {
        HStack(spacing: 0) {
            if let note = selectedNote {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        header(note)
                        Text("Edited \(note.edited.formatted(date: .long, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 40)
                    // Full width, so its scroll bar is at the pane's edge; the page keeps the text in the same column.
                    NoteEditor(noteID: note.id, fontSize: 15, titleLine: true, focusIfEmpty: !editingAddress,
                               openLink: { peekID = $0 })
                }
                .padding(.top, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: targetFocused) { _, focused in editingAddress = focused }
                if let peekID, model.notes.contains(where: { $0.id == peekID }) {
                    Divider()
                    peek(peekID)
                }
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "note.text",
                                       description: Text("Pick a note in the sidebar, or press ⌘N to start one."))
            }
            if inspectorShown {
                Divider()
                inspector
                    .frame(width: 260)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Inspector")
            }
        }
    }

    /// A linked page beside the note it's linked from, like Notion's side peek: the answer next to the question.
    private func peek(_ id: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Button { peekID = nil } label: { Label("Close Peek", systemImage: "xmark") }
                    .help("Close the peek")
                Spacer()
                Button { selection = id } label: { Label("Open as Main Note", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Open this page in the main view")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            NoteEditor(noteID: id, toolbar: false, fontSize: 14, titleLine: true, focusIfEmpty: false, openLink: { peekID = $0 })
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Linked page")
    }

    /// The source chip, or the address field while editing it. A note without one gets it from its row's menu (D84).
    @ViewBuilder
    private func header(_ note: Note) -> some View {
        if note.kind == .url && editingAddress {
            TextField("Page address, e.g. github.com/vercel/next.js", text: targetBinding(note.id))
                .textFieldStyle(.roundedBorder)
                .focused($targetFocused)
                .task(id: note.id) { if editingAddress { targetFocused = true } }
                .onSubmit { targetFocused = false }
                .onExitCommand { targetFocused = false }
                .onChange(of: targetFocused) { _, focused in
                    // Done editing: the key the extension makes, so a pasted YouTube link keeps only its video (D70).
                    let target = model.binding(note.id, \.target)
                    guard !focused, let url = URL(string: "https://" + target.wrappedValue) else { return }
                    let page = Note.pageTarget(url)
                    if !page.isEmpty, page != target.wrappedValue { target.wrappedValue = page }
                }
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
        switchTo(.notes)
        query = ""
        editingAddress = false
        selection = model.add(kind: .url, target: "", label: "", folderID: folderFilter).id  // in the folder you're looking at
        if starredOnly, let id = selection { model.update(id) { $0.starred = true } }  // or it would vanish from Starred
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

/// An Apple Notes list row: bold title; the icon of the app or site it belongs to, the date, the preview. Two lines;
/// the source's name is in the tooltip and on the note's chip (D84).
struct NoteRow: View {
    let note: Note
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                Text(note.title).font(.headline).lineLimit(1)
                if note.starred {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.notesAccent).accessibilityLabel("Starred")
                }
            }
            HStack(spacing: 4) {
                if note.hasSource { NoteIcon(note: note, size: 12) }
                (Text(date) + Text("  ") + Text(note.preview.isEmpty ? "No additional text" : note.preview).foregroundStyle(.secondary))
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(note.hasSource ? note.shortSource : "")
        .accessibilityValue(note.hasSource ? note.shortSource : "")
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }  // a hairline between notes, like Notes
        .overlay(alignment: .leading) {  // the colour label: a strip at the sidebar's edge, like a Chrome tab group's
            if let color = note.color {
                Capsule().fill(color.swatch).frame(width: 4).padding(.vertical, 4).offset(x: -12)
                    .accessibilityLabel("\(color.title) label")
            }
        }
        .accessibilityElement(children: .combine)
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
            .padding(.top, 12)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(note.title)
            .tint(.notesAccent)
        } else {
            ContentUnavailableView("Note Deleted", systemImage: "trash", description: Text("This note no longer exists."))
        }
    }
}

/// A colour menu: a note's label in the sidebar, one event's own colour in the calendar.
struct ColorLabelMenu: View {
    let current: NoteColor?
    let set: (NoteColor?) -> Void

    var body: some View {
        Menu {
            Button("None") { set(nil) }.disabled(current == nil)
            Divider()
            ForEach(NoteColor.allCases, id: \.self) { color in
                Button { set(color) } label: {
                    Label { Text(color.title) } icon: { Image(nsImage: Self.dot(color)) }
                }
                .disabled(current == color)
            }
        } label: { Label("Color", systemImage: "circle.lefthalf.filled") }
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
}

extension View {
    /// macOS 26's soft scroll edges let rows show through the sidebar's search field and its bottom bar, where both
    /// become hard to read; hard edges hide them behind the bars instead.
    @ViewBuilder
    func hardScrollEdges() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.hard, for: .vertical)
        } else {
            self
        }
    }

    /// A bar pinned under a list: on macOS 26 a safe-area bar, so the list's scroll edge covers it; before that, a
    /// bar-coloured inset rows can't show through.
    @ViewBuilder
    func bottomBar(@ViewBuilder _ bar: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar().background(.bar) }
        }
    }
}

extension NotesWindow {
    /// 0.1.3 could save pane widths from a runaway layout (D80), which AppKit restores at every launch. A pane wider
    /// than its window is never right, so the window then starts from its default widths.
    static func forgetRunawayPaneWidths(in defaults: UserDefaults = .standard) {
        let key = "NSSplitView Subview Frames notes, SidebarNavigationSplitView"
        func width(_ field: Substring?) -> Double? { field.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        // "x y width height …" and, per pane, "x, y, width, height, collapsed, hidden".
        guard let window = width(defaults.string(forKey: "NSWindow Frame notes")?.split(separator: " ").dropFirst(2).first),
              let panes = defaults.stringArray(forKey: key),
              panes.contains(where: { (width($0.split(separator: ",").dropFirst(2).first) ?? 0) > window + 1 })
        else { return }
        defaults.removeObject(forKey: key)
    }
}
