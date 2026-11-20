import AppKit
import OSLog
import SwiftUI
import Testing
@testable import MemoryNotes

/// Opt-in (MN_UI_PROBE=1): hosts the real main window off-screen with a note open and drags the sidebar divider with
/// real mouse events, with the inspector hidden and shown, in a roomy window and the narrowest one allowed.
/// On macOS 26 every split view in the window added the floating sidebar's width (and the inspector's) to the note's
/// minimum once more: 320 + 2 × (298 + 260) + 260 = 1,696 points in a 1,296-point window. SwiftUI centred what didn't
/// fit, 200 points past both edges, and each drag fed that back until panes were thousands of points wide and the
/// window drew blank (D78, D80). Now one split view decides the widths, and no pane may reach past the window.
/// Run it alone (`--filter dividerDrags`): it shares the notes model and the main run loop with other tests.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["MN_UI_PROBE"] != nil))
func dividerDragsKeepEveryPaneInsideTheWindow() throws {
    _ = SyncStoreTests.dir  // the scratch store, never the real notes
    #expect(NoteStore.root.path == SyncStoreTests.dir, "would touch the real notes database")
    guard NoteStore.root.path == SyncStoreTests.dir else { return }
    if NotesModel.shared.notes.count < 12 {
        for i in 0..<12 { _ = NotesModel.shared.add(kind: .url, target: "example.com/\(i)", label: "", text: "Note \(i)\n#project-\(i % 3) #bug") }
    }
    defer { UserDefaults.standard.removeObject(forKey: "inspectorShown") }
    _ = NSApplication.shared
    // One test looping over the cases, not one test case each: between cases Swift Testing went back to the main run
    // loop, which had returned, and the test process exited before the next case.
    for (width, inspectorShown) in [(CGFloat(1296), false), (1296, true), (760, true)] {
        try probe(width: width, inspectorShown: inspectorShown)
    }
}

@MainActor private func probe(width: CGFloat, inspectorShown: Bool) throws {
    UserDefaults.standard.set(inspectorShown, forKey: "inspectorShown")
    NotesModel.shared.openRequest = NotesModel.shared.notes.first?.id  // a note open, as people have it
    let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: 0, width: width, height: 860),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: NotesWindow())
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    spin(1.5)
    let content = window.contentView!
    let setup = "\(Int(width))-point window, inspector \(inspectorShown ? "shown" : "hidden")"

    let splits = allViews(in: content).compactMap { $0 as? NSSplitView }
    #expect(splits.count == 1, "\(setup): one split view decides the widths; found \(splits.count)")
    let split = try #require(splits.first, "\(setup): no split view, the window didn't build")
    var worst = (overreach(in: content, width: width), "at start")
    var sidebar = [split.arrangedSubviews[0].frame.width]
    // Out past the sidebar's widest, back to a usual width, then far left, which collapses it as in any Mac app;
    // measured after each drag. (A collapsed pane keeps reporting its last width.)
    for (move, step) in [(250, "after dragging out"), (-150, "after dragging back"), (-400, "after collapsing")] {
        let edge = split.arrangedSubviews[0].convert(split.arrangedSubviews[0].bounds, to: nil).maxX - 1
        // Press only on the divider: anywhere else a click could land on a link and open the real browser.
        guard content.hitTest(NSPoint(x: edge, y: content.bounds.midY)) === split else {
            Issue.record("\(setup), \(step): the divider isn't under x \(Int(edge)), so no click was made"); break
        }
        drag(in: window, from: edge, by: stride(from: move.signum() * 10, through: move, by: move.signum() * 10).map { CGFloat($0) })
        let reach = overreach(in: content, width: width)
        if reach > worst.0 { worst = (reach, step) }
        sidebar.append(split.arrangedSubviews[0].frame.width)
    }
    #expect(sidebar[1] > sidebar[0] + 50 && sidebar[2] < sidebar[1] - 50, "\(setup): the drags didn't move the sidebar: \(sidebar)")
    if inspectorShown {  // 260 wide, whole, at the window's right edge
        let inspector = allViews(in: content).filter {
            let f = $0.convert($0.bounds, to: nil); return abs(f.width - 260) < 1 && abs(f.maxX - width) < 2 && f.height > 400
        }
        #expect(!inspector.isEmpty, "\(setup): the inspector isn't showing")
    }
    let textureErrors = try OSLogStore(scope: .currentProcessIdentifier).getEntries()
        .compactMap { $0 as? OSLogEntryLog }.filter { $0.composedMessage.contains("unable to create texture") }.count
    #expect(worst.0 < 1, "\(setup): a pane reached \(Int(worst.0)) points past the window \(worst.1)")
    #expect(textureErrors == 0, "\(setup): the GPU couldn't draw a layer")
}

/// 0.1.3 saved the runaway widths and restored them at every launch; this is the layout it saved on 2026-11-20.
@Test func runawayPaneWidthsAreForgotten() throws {
    let suite = "MemoryNotesTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "NSSplitView Subview Frames notes, SidebarNavigationSplitView"
    defaults.set("100 80 1296 860 0 0 1512 949 ", forKey: "NSWindow Frame notes")
    defaults.set(["0.000000, 0.000000, 298.000000, 860.000000, NO, NO", "0.000000, 0.000000, 1296.000000, 860.000000, NO, NO"], forKey: key)
    NotesWindow.forgetRunawayPaneWidths(in: defaults)
    #expect(defaults.stringArray(forKey: key)?.count == 2, "a sound layout is kept")
    defaults.set(["0.000000, 0.000000, 4288.000000, 860.000000, NO, NO", "0.000000, 0.000000, 9556.000000, 860.000000, NO, NO"], forKey: key)
    NotesWindow.forgetRunawayPaneWidths(in: defaults)
    #expect(defaults.stringArray(forKey: key) == nil, "a runaway layout is dropped")
}

/// macOS moves titled windows back onto a screen; this one stays off every screen, so the probe is never seen.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

@MainActor private func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { allViews(in: $0) } }

/// How far the split view or any of its panes reaches past the window's left or right edge (0 when inside).
@MainActor private func overreach(in content: NSView, width: CGFloat) -> CGFloat {
    let splits = allViews(in: content).compactMap { $0 as? NSSplitView }
    return (splits + splits.flatMap(\.arrangedSubviews)).map {
        let f = $0.convert($0.bounds, to: nil); return max(0, -f.minX, f.maxX - width)
    }.max() ?? 0
}

/// A mouse drag: down at `x`, a move to each offset, up. Posted to this process's own event queue, where the split
/// view's tracking loop reads them, so nothing reaches the real mouse or another app.
@MainActor private func drag(in window: NSWindow, from x: CGFloat, by offsets: [CGFloat]) {
    let y = window.contentView!.bounds.midY
    func event(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x + dx, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    for dx in offsets { NSApp.postEvent(event(.leftMouseDragged, dx), atStart: false) }
    NSApp.postEvent(event(.leftMouseUp, offsets.last ?? 0), atStart: false)
    window.sendEvent(event(.leftMouseDown, 0))
    spin(0.5)
}

