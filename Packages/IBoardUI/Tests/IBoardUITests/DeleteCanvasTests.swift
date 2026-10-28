import XCTest
@testable import IBoardUI

final class DeleteCanvasTests: XCTestCase {
    func testMarksPlannedWordsAndKeepsRest() {
        let base = "hello brave new world"
        let plan = BackspaceSwipePlan.plan(before: base, extraDistance: 0)
        let m = DeleteCanvasModel.make(base: base, plan: plan)
        XCTAssertEqual(m.kept + m.doomed, base)
        XCTAssertEqual(m.doomed, "world")
        XCTAssertEqual(m.caption, "Delete 1 word")
    }

    func testMoreDistanceCoversMoreWords() {
        let base = "one two three four"
        let plan = BackspaceSwipePlan.plan(before: base, extraDistance: BackspaceSwipePlan.wordStep * 2)
        let m = DeleteCanvasModel.make(base: base, plan: plan)
        XCTAssertEqual(m.caption, "Delete 3 words")
        XCTAssertEqual(m.kept, "one ")
    }

    func testNoPlanYetHint() {
        let m = DeleteCanvasModel.make(base: "abc def", plan: BackspaceSwipePlan(words: 0, graphemes: 0, preview: ""))
        XCTAssertEqual(m.doomed, "")
        XCTAssertEqual(m.kept, "abc def")
        XCTAssertTrue(m.caption.contains("Drag"))
    }

    func testSecureFieldWithoutContext() {
        let m = DeleteCanvasModel.make(base: "", plan: BackspaceSwipePlan(words: 0, graphemes: 0, preview: ""))
        XCTAssertEqual(m.kept, "")
        XCTAssertEqual(m.caption, "No preview in this field")
    }

    func testNewlinesAreVisibleAndEmojiSurvive() {
        let base = "line one\nfamily 👨‍👩‍👧 ok"
        let plan = BackspaceSwipePlan.plan(before: base, extraDistance: BackspaceSwipePlan.wordStep * 2)
        let m = DeleteCanvasModel.make(base: base, plan: plan)
        XCTAssertFalse((m.kept + m.doomed).contains("\n"))
        XCTAssertTrue((m.kept + m.doomed).contains("👨‍👩‍👧"))
    }

    func testLongTextIsClippedNearCursor() {
        let base = String(repeating: "word ", count: 100) + "tail"
        let plan = BackspaceSwipePlan.plan(before: base, extraDistance: 0)
        let m = DeleteCanvasModel.make(base: base, plan: plan)
        XCTAssertTrue(m.kept.hasPrefix("\u{2026}"))
        XCTAssertLessThanOrEqual(m.kept.count, DeleteCanvasModel.keptLimit + 1)
        XCTAssertEqual(m.doomed, "tail")
    }

    func testContextLimitedFlag() {
        let base = String(repeating: "a", count: 500)
        let plan = BackspaceSwipePlan.plan(before: base, extraDistance: 0)
        XCTAssertTrue(DeleteCanvasModel.make(base: base, plan: plan).contextLimited)
        let short = DeleteCanvasModel.make(base: "hi there", plan: BackspaceSwipePlan.plan(before: "hi there", extraDistance: 99))
        XCTAssertFalse(short.contextLimited)
    }

    func testSecureFieldDeletesByCharacterAndShowsOnlyDots() {
        XCTAssertEqual(BackspaceSwipePlan.characterPlan(extraDistance: 0).graphemes, 1)
        XCTAssertEqual(BackspaceSwipePlan.characterPlan(extraDistance: 14 * 4 + 1).graphemes, 5)
        let m = DeleteCanvasModel.make(base: "", plan: BackspaceSwipePlan.characterPlan(extraDistance: 30))
        XCTAssertEqual(m.caption, "Delete 3 characters")
        XCTAssertEqual(m.doomed, "\u{2022}\u{2022}\u{2022}")
        XCTAssertTrue(m.kept.isEmpty)
    }
}
