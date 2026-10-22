import XCTest

/// All records are created through native controls in a dedicated random local
/// test workspace. No account, backend response or existing user data is faked.
@MainActor final class FieldLogUITests: XCTestCase {
  func testOfflineWorkflowPreservesDraftAcrossRelaunchAndSharesReport() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--fieldlog-ui-workspace", UUID().uuidString]
    app.launch()
    XCTAssertTrue(
      app.staticTexts["test-workspace-badge"].waitForExistence(timeout: 15),
      "Refuse all mutations unless dedicated test workspace is confirmed")
    XCTAssertTrue(app.buttons["create-first-project"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["OFFLINE WORKSPACE"].exists)
    screenshot("01-empty-offline-workspace", app)

    app.buttons["create-first-project"].tap()
    let projectName = app.textFields["project-name"]
    XCTAssertTrue(projectName.waitForExistence(timeout: 5))
    projectName.tap()
    projectName.typeText("UI Test workshop")
    app.buttons["save-project"].tap()
    XCTAssertTrue(app.navigationBars["UI Test workshop"].waitForExistence(timeout: 10))
    try addTask("Measure opening", app)
    try addTask("Take field notes", app)
    let first = app.buttons["Measure opening, not completed"]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    first.tap()
    XCTAssertTrue(app.buttons["Measure opening, completed"].waitForExistence(timeout: 5))
    app.buttons["Task options: Measure opening"].tap()
    XCTAssertTrue(app.buttons["Move down"].waitForExistence(timeout: 5))
    app.buttons["Move down"].tap()
    let reordered = NSPredicate { _, _ in
      app.buttons["Take field notes, not completed"].frame.minY
        < app.buttons["Measure opening, completed"].frame.minY
    }
    expectation(for: reordered, evaluatedWith: nil)
    waitForExpectations(timeout: 5)
    screenshot("02-checklist-completed-and-reordered", app)

    reveal(app.buttons["add-entry"], in: app)
    app.buttons["add-entry"].tap()
    let title = input("entry-title", app)
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText("Morning field note")
    let note = "Draft line one\nSpacing stays:  two spaces."
    let editor = app.textViews["entry-note"]
    editor.tap()
    editor.typeText(note)
    app.buttons["Done"].tap()
    let draft = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Morning field note"))
      .firstMatch
    XCTAssertTrue(draft.waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.navigationBars["UI Test workshop"].waitForExistence(timeout: 15))
    let restored = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Morning field note")
    ).firstMatch
    reveal(restored, in: app)
    restored.tap()
    XCTAssertEqual(input("entry-title", app).value as? String, "Morning field note")
    XCTAssertEqual(app.textViews["entry-note"].value as? String, note)
    screenshot("03-restored-lossless-draft", app)
    reveal(app.buttons["save-entry"], in: app)
    app.buttons["save-entry"].tap()
    XCTAssertTrue(app.navigationBars["UI Test workshop"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Morning field note"].waitForExistence(timeout: 5))
    app.buttons["Share report"].tap()
    XCTAssertTrue(
      app.otherElements["ActivityListView"].waitForExistence(timeout: 10), app.debugDescription)
    let caption = app.descendants(matching: .any).matching(identifier: "LP.CaptionBar.TopCaption")
      .firstMatch
    XCTAssertTrue(caption.waitForExistence(timeout: 5))
    XCTAssertTrue(caption.label.hasPrefix("FieldLog-"))
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy"))
        .firstMatch.exists)
    screenshot("04-native-report-share-sheet", app)
    app.buttons["Close"].tap()
    app.tabBars.buttons["On device"].tap()
    XCTAssertTrue(
      app.staticTexts[
        "Cloud sync isn't connected. Nothing in this queue has been sent to a server."
      ].waitForExistence(timeout: 5))
    screenshot("05-local-pending-changes-not-sent", app)
    // Do not select any external share destination or send a message.
    app.terminate()
  }

  private func addTask(_ text: String, _ app: XCUIApplication) throws {
    let add = app.buttons["Add task"]
    reveal(add, in: app)
    add.tap()
    let title = input("task-title", app)
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    title.typeText(text)
    app.navigationBars["New task"].buttons["Add"].tap()
    XCTAssertTrue(app.buttons[text + ", not completed"].waitForExistence(timeout: 10))
  }
  private func input(_ id: String, _ app: XCUIApplication) -> XCUIElement {
    app.textFields[id].exists ? app.textFields[id] : app.textViews[id]
  }
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<5 {
      if element.isHittable { return }
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable, app.debugDescription)
  }
  private func screenshot(_ name: String, _ app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
