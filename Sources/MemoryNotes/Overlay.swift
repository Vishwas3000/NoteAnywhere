import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating panel that follows the frontmost app: it opens by itself when that app has notes.
final class OverlayController {
    private let model = NotesModel.shared
    private var subscription: AnyCancellable?

    private lazy var panel: NSPanel = {
        // Non-activating: typing in the panel doesn't steal "frontmost" from the app the notes are about.
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.makeFloating()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false  // MemoryNotes is almost never the active app
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OverlayView())
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 340, y: screen.maxY - 20))
        }
        panel.setFrameAutosaveName("MemoryNotesOverlay")
        return panel
    }()

    func start() {
        subscription = FrontWindow.shared.$context.removeDuplicates().sink { [weak self] context in self?.contextChanged(context) }
        HotKeys.register(kVK_ANSI_M, optionKey | shiftKey, name: "⌥⇧M") { [weak self] in self?.toggle() }
    }

    func toggle() {
        panel.isVisible ? panel.orderOut(nil) : show(model.frontApp)
    }

    private func contextChanged(_ context: String?) {
        guard let context, !model.notes(inContext: context).isEmpty else { return panel.orderOut(nil) }
        show(model.frontApp)
    }

    private func show(_ app: NSRunningApplication?) {
        panel.title = app?.localizedName ?? "NoteAnywhere"
        panel.moveToMouseScreen()
        panel.orderFrontRegardless()
    }
}

extension NSPanel {
    /// Borderless-looking panel: glass/material content shows through, only the close button stays (where present).
    func makeFloating() {
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
    }

    /// With several displays, brings the panel to the one under the mouse pointer.
    func moveToMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let current = screen ?? NSScreen.main, target != current else { return }
        setFrameOrigin(Self.origin(of: frame, from: current.visibleFrame, to: target.visibleFrame))
    }

    /// Same offset from the top-right corner on the new screen, kept fully on it.
    static func origin(of frame: NSRect, from: NSRect, to: NSRect) -> NSPoint {
        let x = to.maxX - (from.maxX - frame.maxX) - frame.width
        let y = to.maxY - (from.maxY - frame.maxY) - frame.height
        return NSPoint(x: min(max(x, to.minX), to.maxX - frame.width), y: min(max(y, to.minY), to.maxY - frame.height))
    }
}

extension View {
    /// Liquid Glass on macOS 26, a material before that.
    @ViewBuilder
    func floatingBackground() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct OverlayView: View {
    @ObservedObject private var model = NotesModel.shared
    @ObservedObject private var front = FrontWindow.shared  // redraw when the app or place in front changes
    @Environment(\.openWindow) private var openWindow
    @State private var searching = false
    @State private var query = ""
    @State private var selection = 0
    @State private var submits = 0
    @State private var pendingDelete: Note?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let app = model.frontApp, let id = app.bundleIdentifier, let context = model.frontContext {
                content(app, name: app.localizedName ?? id, context: context)
            } else {
                ContentUnavailableView("No App in Front", systemImage: "macwindow",
                                       description: Text("Switch to an app to see its notes."))
            }
        }
        // The hosting view sizes the panel to this; without it the ScrollView collapses to zero height.
        .frame(minWidth: 260, idealWidth: 320, minHeight: 180, idealHeight: 420, alignment: .top)
        .floatingBackground()
        .tint(.notesAccent)
        .confirmationDialog("Delete this note?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { note in
            Button("Delete", role: .destructive) { model.delete(note.id) }
        } message: { note in
            Text("“\(note.title)” will be removed.")
        }
    }

    private func content(_ app: NSRunningApplication, name: String, context: String) -> some View {
        let place = context.split(separator: "/").dropFirst().joined(separator: " › ")
        let notes = model.notes(inContext: context).reversed()  // newest first, like Apple Notes
        let newNote = {
            closeSearch()
            model.add(kind: .app, target: context, label: name)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.headline).lineLimit(1)
                    if !place.isEmpty {
                        Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Group {
                    Button { if searching { closeSearch() } else { searching = true } } label: {
                        Label(searching ? "Close Search" : "Search All Notes", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f")
                    .help(searching ? "Close Search" : "Search All Notes (⌘F)")
                    Button { newNote() } label: { Label("New Note", systemImage: "plus") }
                        .keyboardShortcut("n")
                        .help("New Note (⌘N)")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .imageScale(.large)
                .foregroundStyle(.secondary)  // borderless icons would take the yellow tint, too faint on light glass
            }
            .padding(.leading, 22)  // clear of the close button in the transparent title bar

            if !AXIsProcessTrusted() {  // without it, notes can only follow the app, not the chat or file
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Allow Accessibility to see which chat or file you're in.").font(.caption)
                    Spacer(minLength: 4)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if searching {
                TextField("Search all notes", text: $query, prompt: Text("\(Image(systemName: "magnifyingglass")) Search all notes"))
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onAppear { searchFocused = true }
                    .onExitCommand { if query.isEmpty { closeSearch() } else { query = "" } }
                    .onKeyPress(.downArrow) { selection += 1; return .handled }
                    .onKeyPress(.upArrow) { selection -= 1; return .handled }
                    .onSubmit { submits += 1 }
                    .accessibilityHint("Up and Down Arrow choose a note, Return edits it, Escape clears the search")
                    .transition(.opacity)
            }

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResultsView(query: query, selection: $selection, submits: submits)
            } else if notes.isEmpty {
                let here = place.isEmpty ? name : place
                ContentUnavailableView {
                    Label("No Notes Here Yet", systemImage: "note.text")
                } description: {
                    Text("Write one and it will be waiting when you come back.")
                } actions: {
                    Button { newNote() } label: { Text("New Note for \(here)").lineLimit(1).truncationMode(.middle) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .environment(\.controlActiveState, .key)  // the overlay is rarely key; it would turn grey
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    // Not Lazy: recreating a WKWebView editor on scroll would drop its undo history and measured height.
                    VStack(spacing: 10) {
                        ForEach(notes) { note in
                            NoteCard(note: note, delete: { requestDelete(note) }, open: { open(note) })
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Notes")
                }
            }
        }
        .padding(12)
        .animation(.easeOut(duration: 0.15), value: searching)
    }

    private func closeSearch() {
        searching = false
        query = ""
    }

    private func requestDelete(_ note: Note) {
        if note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.delete(note.id)
        } else {
            pendingDelete = note
        }
    }

    private func open(_ note: Note) {
        model.openRequest = note.id
        openWindow(id: "notes")
        NSApp.activate()
    }
}

/// One note in the overlay: its editor on a soft card. Open and Delete show on hover or keyboard focus,
/// and are always there for VoiceOver as actions.
private struct NoteCard: View {
    let note: Note
    let delete: () -> Void
    let open: () -> Void
    @State private var hovering = false
    @FocusState private var focusedAction: Int?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                TimelineView(.everyMinute) { _ in Text("Edited \(note.editedAgo)") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Group {
                    Button(action: open) { Label("Open in NoteAnywhere", systemImage: "arrow.up.forward.app") }
                        .help("Open in NoteAnywhere")
                        .focused($focusedAction, equals: 0)
                    Button(action: delete) { Label("Delete Note", systemImage: "trash") }
                        .help("Delete Note")
                        .focused($focusedAction, equals: 1)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering || focusedAction != nil ? 1 : 0)
            }
            NoteEditor(noteID: note.id, toolbar: false, fit: 44...320) {
                openWindow(id: "notes")
                NSApp.activate()
            }
        }
        .padding(10)
        .background(hovering ? .quaternary : .quinary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {  // the note's colour label, like a Chrome tab group's strip
            if let color = note.color {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(color.swatch).frame(width: 4)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if contrast == .increased { RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary) }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title)
        .accessibilityAction(named: "Open in NoteAnywhere", open)
        .accessibilityAction(named: "Delete Note", delete)
    }
}
