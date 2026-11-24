import XCTest

/// The note's More ▸ Find in Note opens iOS's find bar over the editor, keyboard up, and counts the matches.
final class FindInNoteTests: XCTestCase {
    func testFindInNote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleNotes", "-tab", "notes", "-openNote", "", "-search", ""]
        app.launch()
        let row = app.buttons.containing(.staticText, identifier: "Next.js caching").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        app.buttons["Find in Note"].tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "iOS's find bar")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up without another tap")
        app.typeText("cache")
        // "use cache" and "unstable_cache" in the note's two lines: the bar says "1 of 2".
        let count = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "1 of [0-9]+")).firstMatch
        let found = count.waitForExistence(timeout: 5)
        sleep(1)  // the scroll to the match
        let web = app.webViews.firstMatch.frame
        let match = app.webViews.staticTexts["use cache"].firstMatch.frame
        XCTAssertTrue(web.contains(match), "the match is scrolled into view: \(match) in \(web)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "find"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(found, "a match count: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    /// The editor handles the keyboard itself (for the find bar): lines typed past the keyboard's top still scroll into view.
    func testTypingStaysAboveTheKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedSampleNotes", "-tab", "notes", "-openNote", "", "-search", ""]
        app.launch()
        let new = app.buttons["New Note"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        let text = app.webViews.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Keyboard check" + String(repeating: "\nline", count: 14) + "\nlast line here")
        sleep(1)
        let last = app.webViews.staticTexts["last line here"].firstMatch.frame
        let keyboard = app.keyboards.firstMatch.frame
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "typing"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertLessThanOrEqual(last.maxY, keyboard.minY, "the line being typed is above the keyboard: \(last) vs \(keyboard)")

        app.buttons["More"].tap()  // leave the simulator's notes as they were
        app.buttons["Delete"].tap()
        app.buttons["Delete Note"].tap()
    }
}
