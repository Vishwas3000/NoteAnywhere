import AppKit
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
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
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
        subscription = model.$frontApp.sink { [weak self] app in self?.frontAppChanged(app) }
    }

    func toggle() {
        panel.isVisible ? panel.orderOut(nil) : show(model.frontApp)
    }

    private func frontAppChanged(_ app: NSRunningApplication?) {
        guard let id = app?.bundleIdentifier, !model.notes(forApp: id).isEmpty else { return panel.orderOut(nil) }
        show(app)
    }

    private func show(_ app: NSRunningApplication?) {
        panel.title = app?.localizedName ?? "MemoryNotes"
        panel.orderFrontRegardless()
    }
}

struct OverlayView: View {
    @ObservedObject private var model = NotesModel.shared

    var body: some View {
        if let app = model.frontApp, let id = app.bundleIdentifier {
            let name = app.localizedName ?? id
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.notes(forApp: id)) { note in
                            HStack(alignment: .top, spacing: 4) {
                                TextEditor(text: model.binding(note.id, \.text))
                                    .font(.body)
                                    .frame(height: 90)
                                    .scrollContentBackground(.hidden)
                                    .padding(4)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                Button { model.delete(note.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Delete note")
                            }
                        }
                    }
                }
                Button("+ Note for \(name)") { model.add(kind: .app, target: id, label: name) }
            }
            .padding(10)
            // The hosting view sizes the panel to this; without it the ScrollView collapses to zero height.
            .frame(minWidth: 240, idealWidth: 300, minHeight: 160, idealHeight: 320)
        } else {
            Text("Switch to an app to see its notes.").padding()
        }
    }
}
