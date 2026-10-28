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
                ForEach(NoteDates.sections(model.notes)) { section in
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
            .contextMenu {
                if let url = pageURL(note) {
                    pageActions(url)
                    Divider()
                }
                Button("Delete…", role: .destructive) { pendingDelete = note }
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
        selection = model.add(kind: .url, target: "", label: "").id
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
            Text(note.title).font(.headline).lineLimit(1)
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
