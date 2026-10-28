import XCTest

/// A task dated with @yyyy-MM-dd shows under Planned on its day, and its circle ticks the checkbox in the note.
final class CalendarTaskTests: XCTestCase {
    func testTickPlannedTask() throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let app = XCUIApplication()
        // The sample notes plan two tasks two days from now.
        app.launchArguments = ["-seedSampleNotes", "-tab", "calendar", "-calendarDay", f.string(from: .now.addingTimeInterval(2 * 86_400))]
        app.launch()

        let task = app.buttons["Not done"].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        let open = app.buttons.matching(identifier: "Not done").count
        task.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Not done").count, open - 1)
        app.buttons["Done"].firstMatch.tap()  // and back, leaving the sample as it was
        XCTAssertTrue(app.buttons.matching(identifier: "Done").firstMatch.waitForNonExistence(timeout: 5))
    }
}
