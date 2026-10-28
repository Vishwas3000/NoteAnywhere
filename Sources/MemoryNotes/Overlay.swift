import AppKit
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
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 340),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.makeFloating()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false  // MemoryNotes is almost never the active app
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OverlayView())
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 320, y: screen.maxY - 20))
        }
        panel.setFrameAutosaveName("MemoryNotesOverlay")
        return panel
    }()

    func start() {
        subscription = model.$frontContext.removeDuplicates().sink { [weak self] context in self?.contextChanged(context) }
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
        panel.title = app?.localizedName ?? "MemoryNotes"
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
    @State private var query = ""
    @State private var pendingDelete: Note?

    var body: some View {
        if let app = model.frontApp, let id = app.bundleIdentifier, let context = model.frontContext {
            let name = app.localizedName ?? id
            let place = context.split(separator: "/").dropFirst().joined(separator: " › ")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).font(.headline).lineLimit(1)
                        if !place.isEmpty {
                            Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                }
                .padding(.leading, 20)  // clear of the close button in the transparent title bar
                TextField("Search all notes", text: $query, prompt: Text("\(Image(systemName: "magnifyingglass")) Search all notes"))
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand { query = "" }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsView(query: query)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.notes(inContext: context)) { note in
                                HStack(alignment: .top, spacing: 4) {
                                    NoteEditor(noteID: note.id, toolbar: false)
                                        .frame(height: 110)
                                        .padding(4)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                        .accessibilityLabel("Note for \(note.place)")
                                    Button {
                                        if note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            model.delete(note.id)
                                        } else {
                                            pendingDelete = note
                                        }
                                    } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                        .help("Delete note")
                                        .accessibilityLabel("Delete note")
                                }
                            }
                        }
                    }
                    Button { model.add(kind: .app, target: context, label: name) } label: {
                        Label("New Note for \(place.isEmpty ? name : place)", systemImage: "plus")
                    }
                }
            }
            .padding(10)
            // The hosting view sizes the panel to this; without it the ScrollView collapses to zero height.
            .frame(minWidth: 240, idealWidth: 300, minHeight: 160, idealHeight: 320, alignment: .top)
            .floatingBackground()
            .confirmationDialog("Delete this note?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { note in
                Button("Delete", role: .destructive) { model.delete(note.id) }
            } message: { _ in
                Text("This can't be undone.")
            }
        } else {
            Text("Switch to an app to see its notes.").padding().floatingBackground()
        }
    }
}
