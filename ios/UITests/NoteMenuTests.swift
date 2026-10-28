import XCTest

/// The long-press menu pins a note: it moves into the Pinned section.
final class NoteMenuTests: XCTestCase {
    func testPinFromMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleNotes", "-tab", "notes", "-openNote", "", "-search", ""]
        app.launch()
        let row = app.buttons.containing(.staticText, identifier: "Next.js caching").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        let pin = app.buttons["Pin Note"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "menu"
        shot.lifetime = .keepAlways
        add(shot)
        pin.tap()
        let pinned = app.staticTexts["Pinned"].firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 5))
        // Pinned rows come first, so the note now sits between the Pinned header and Today.
        XCTAssertLessThan(row.frame.minY, app.staticTexts["Today"].firstMatch.frame.minY)

        row.press(forDuration: 1.2)
        app.buttons["Unpin Note"].tap()  // leave the sample as it was
    }
}
