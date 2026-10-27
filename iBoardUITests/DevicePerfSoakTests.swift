import XCTest

/// On-device typing soak (M13-02 helper). Duration via env IBOARD_SOAK_SECONDS (default 60). Taps and drags at
/// pseudo-random grid positions; asserts nothing about text. The keyboard writes counts/footprint to
/// Library/Caches/perf-metrics.json (build with -DIBOARD_PERF); read it with devicectl (docs/perf/README.md).
final class DevicePerfSoakTests: XCTestCase {
    @MainActor
    func testSoak() throws {
        let seconds = Double(ProcessInfo.processInfo.environment["IBOARD_SOAK_SECONDS"] ?? "") ?? 60
        let app = XCUIApplication()
        app.launch()
        let fields = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue))
        let field = fields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<3 where !field.isHittable { app.swipeUp() }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 4)
        XCTContext.runActivity(named: "after-tap") { a in a.add(XCTAttachment(screenshot: app.screenshot())) }
        print("IBOARD_SOAK_FIELDS", fields.count, app.keyboards.count, field.isHittable)
        let grid = app.descendants(matching: .any).matching(identifier: "key-grid").firstMatch
        if !grid.waitForExistence(timeout: 4) {
            // Cycle keyboards with the globe key until iBoard shows (at most 6 taps).
            let globe = app.buttons["Next keyboard"].firstMatch
            for _ in 0..<6 where globe.exists && !grid.exists { globe.tap(); _ = grid.waitForExistence(timeout: 2) }
        }
        guard grid.waitForExistence(timeout: 4) else {
            print("IBOARD_SOAK_TREE", app.keyboards.firstMatch.debugDescription.prefix(1500))
            throw XCTSkip("iBoard keyboard not active: switch to it with the globe key once, then rerun")
        }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let end = Date().addingTimeInterval(seconds)
        var n = 0
        while Date() < end {
            let row = [0.18, 0.40, 0.62][Int(rnd() * 3) % 3]
            let p = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.05 + 0.9 * rnd(), dy: row))
            if n % 25 == 24 { // swipe-typing style drag
                let q = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.05 + 0.9 * rnd(), dy: row))
                p.press(forDuration: 0.05, thenDragTo: q)
            } else if n % 40 == 39 { // backspace area
                grid.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.62)).tap()
            } else {
                p.tap()
            }
            n += 1
        }
        XCTAssertGreaterThan(n, 0)
        print("IBOARD_SOAK_TAPS=\(n)")
    }
}
