import XCTest

/// Starring a note, the Starred filter, the Tags menu, and a plain tap on a #tag in the editor.
final class StarTagsTests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testStarFilterAndTags() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleNotes", "-tab", "notes", "-openNote", "", "-search", ""]
        app.launch()
        let row = app.buttons.containing(.staticText, identifier: "Groceries").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        if app.buttons["Unstar Note"].exists {  // left starred by an earlier, failed run
            app.buttons["Unstar Note"].tap()
            row.press(forDuration: 1.2)
        }
        app.buttons["Star Note"].tap()
        XCTAssertTrue(row.label.contains("Starred"), "the row shows its star: \(row.label)")

        app.buttons["Folders and Tags"].tap()
        app.buttons["Starred"].tap()
        XCTAssertTrue(app.navigationBars["Starred"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.exists)
        XCTAssertFalse(app.staticTexts["Next.js caching"].exists, "only starred notes are listed")
        shot(app, "starred")

        app.buttons["Folders and Tags"].tap()
        app.buttons["All Notes"].tap()
        row.press(forDuration: 1.2)
        app.buttons["Unstar Note"].tap()  // leave the sample as it was
        XCTAssertFalse(row.label.contains("Starred"))

        app.buttons["Folders and Tags"].tap()
        app.buttons["Tags"].tap()
        shot(app, "tags")
        app.buttons["#ml"].tap()
        XCTAssertTrue(app.staticTexts["Results"].waitForExistence(timeout: 10), "a tag searches for it")
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Whisper speech to text").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(row.exists, "Groceries has no #ml")
    }

    func testTapTagInEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleNotes", "-tab", "notes", "-openNote", "", "-search", ""]
        app.launch()
        let row = app.buttons.containing(.staticText, identifier: "Design review").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let tag = app.webViews.staticTexts["#ios"].firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 10))
        shot(app, "editor")
        tag.tap()
        // A plain tap (no ⌘) goes back to the list, searching for the tag.
        XCTAssertTrue(app.staticTexts["Results"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "MiniLM on iOS").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.containing(.staticText, identifier: "Groceries").firstMatch.exists)
        shot(app, "tag-search")
    }

    /// Highlighted text offers the Mac's "Add page" and "Link to a note…"; the second finds notes through the app.
    func testLinkToNote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleNotes", "-tab", "notes", "-openNote", "", "-search", ""]
        app.launch()
        let row = app.buttons.containing(.staticText, identifier: "Groceries").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let line = app.webViews.staticTexts["Coffee beans"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.tap()  // focus first, so the double tap selects a word
        line.doubleTap()
        let link = app.webViews.buttons["Link to a note…"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "a highlight shows the page buttons")
        XCTAssertTrue(app.webViews.buttons["Add page"].exists)
        shot(app, "selection")
        link.tap()
        let found = app.webViews.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Next.js caching'")).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 5), "findNotes lists other notes")
        XCTAssertLessThanOrEqual(app.webViews.firstMatch.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThan(app.webViews.staticTexts["Groceries"].firstMatch.frame.minX, 10, "the page didn't scroll sideways")
        shot(app, "link-to-note")
    }

    func testBlockHandleByTouch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleNotes", "-tab", "notes", "-openNote", "", "-search", ""]
        app.launch()
        let row = app.buttons.containing(.staticText, identifier: "Groceries").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let line = app.webViews.staticTexts["Coffee beans"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.tap()
        shot(app, "handle")
        // The handle (aria-hidden) sits in the left margin beside the tapped block.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 10, dy: line.frame.midY)).tap()
        let search = app.webViews.searchFields["Search block actions"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "a tap on the handle opens the block menu")
        shot(app, "block-menu")
        XCTAssertFalse(search.hasKeyboardFocus, "touch doesn't focus the menu's search")
    }
}

private extension XCUIElement {
    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
