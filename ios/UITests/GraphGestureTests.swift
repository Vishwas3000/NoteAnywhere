import XCTest

/// Touch on the graph: a tap on a hub highlights it, touch-and-hold drags a note, pinch zooms, a tap on a note opens it.
/// Nodes are found through their VoiceOver elements, which sit on the dots.
final class GraphGestureTests: XCTestCase {
    func testGraphGestures() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleNotes", "-tab", "graph", "-graphShowsSimilar", "NO"]
        app.launch()
        let note = app.buttons["MiniLM on iOS"], hub = app.buttons["github.com"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        sleep(6)  // let the layout settle, so the elements sit on their dots
        snap(app, "settled")

        hub.tap()
        snap(app, "hub highlighted")

        let start = note.frame
        center(note).press(forDuration: 1, thenDragTo: center(note).withOffset(CGVector(dx: 0, dy: 160)))
        sleep(6)
        XCTAssertGreaterThan(note.frame.midY - start.midY, 60, "the held note moved with the finger")
        snap(app, "dragged")

        app.windows.firstMatch.pinch(withScale: 1.8, velocity: 2)
        sleep(1)
        snap(app, "pinched")

        app.buttons["Fit Graph"].tap()
        sleep(2)
        center(note).tap()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5), "tapping a note opens it")
        snap(app, "opened")
    }

    private func center(_ element: XCUIElement) -> XCUICoordinate { element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
