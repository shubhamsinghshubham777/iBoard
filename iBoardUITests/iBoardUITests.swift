import XCTest

/// UI smoke tests for the companion app. Navigation works on compact (stack) and regular (sidebar, e.g. iPhone Duo
/// inner display) layouts: `open(_:)` taps whichever list/sidebar row carries the title.
final class iBoardUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        // Pins the @AppStorage "onboarding.completed" flag via the argument domain.
        app.launchArguments += ["-onboarding.completed", onboarded ? "YES" : "NO"]
        app.launch()
        return app
    }

    /// Taps a row (list cell or sidebar item) by its title, scrolling it into view.
    private func open(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let candidates = [app.buttons[title], app.cells.containing(.staticText, identifier: title).firstMatch,
                          app.staticTexts[title]]
        for _ in 0..<6 {
            for c in candidates where c.exists && c.isHittable { c.tap(); return }
            app.swipeUp()
        }
        XCTFail("could not find row \(title)", file: file, line: line)
    }

    private func settingsToggle(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    @MainActor
    func testOnboardingFlowNextBackDone() throws {
        let app = launch(onboarded: false)
        XCTAssertTrue(app.staticTexts["Step 1 of 4"].waitForExistence(timeout: 10))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 4"].waitForExistence(timeout: 3))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 4"].waitForExistence(timeout: 3))
        for n in 2...4 {
            app.buttons["Next"].tap()
            XCTAssertTrue(app.staticTexts["Step \(n) of 4"].waitForExistence(timeout: 3))
        }
        XCTAssertFalse(app.buttons["Next"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 4"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testOnboardingSkip() throws {
        let app = launch(onboarded: false)
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 10))
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 4"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testLaunchShowsSetupWhenOnboarded() throws {
        let app = launch(onboarded: true)
        XCTAssertTrue(app.staticTexts["Set up"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Step 1 of 4"].exists)
    }

    @MainActor
    func testSettingsShowsClipboardHapticAndSyncControls() throws {
        let app = launch(onboarded: true)
        XCTAssertTrue(app.staticTexts["Set up"].firstMatch.waitForExistence(timeout: 10))
        open("Settings", in: app)
        let clipboard = settingsToggle("Clipboard history", in: app)
        for _ in 0..<6 where !clipboard.exists { app.swipeUp() }
        XCTAssertTrue(clipboard.exists, "clipboard toggle missing")
        let haptic = settingsToggle("Haptic feedback", in: app)
        for _ in 0..<6 where !haptic.exists { app.swipeUp() }
        for _ in 0..<12 where !haptic.exists { app.swipeDown() }
        XCTAssertTrue(haptic.exists, "haptic toggle missing")
        let before = haptic.value as? String
        haptic.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertNotEqual(haptic.value as? String, before)
        haptic.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(haptic.value as? String, before)
        open("iCloud sync", in: app)
        XCTAssertTrue(app.navigationBars["iCloud sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Off by default")).firstMatch
            .waitForExistence(timeout: 5))
    }

    @MainActor
    func testThemeStudioOpensAndOffersActions() throws {
        let app = launch(onboarded: true)
        XCTAssertTrue(app.staticTexts["Set up"].firstMatch.waitForExistence(timeout: 10))
        // Compact: Settings > Theme studio. Regular: sidebar row.
        let sidebar = app.staticTexts["Theme studio"]
        if sidebar.waitForExistence(timeout: 2) && sidebar.isHittable { sidebar.tap() } else {
            open("Settings", in: app)
            open("Theme studio", in: app)
        }
        XCTAssertTrue(app.navigationBars["Theme studio"].waitForExistence(timeout: 5))
        let reset = app.buttons["Reset to Native"]
        for _ in 0..<8 where !reset.exists { app.swipeUp() }
        XCTAssertTrue(reset.exists)
    }

    @MainActor
    func testDictionaryManagerAddFieldValidation() throws {
        let app = launch(onboarded: true)
        XCTAssertTrue(app.staticTexts["Set up"].firstMatch.waitForExistence(timeout: 10))
        open("Dictionary", in: app)
        let field = app.textFields["Word"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add"].isEnabled, "Add must be disabled for an empty word")
        field.tap()
        field.typeText("zxqword")
        XCTAssertTrue(app.buttons["Add"].isEnabled)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) { _ = launch(onboarded: true) }
    }
}
