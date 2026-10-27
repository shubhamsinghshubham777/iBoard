import CoreGraphics
import Foundation
import Testing
import IBoardLayout
@testable import IBoardUI

/// A document with a cursor. `adjustPosition` moves in UTF-16 units exactly like the real proxy (it can land inside
/// a cluster), so a test can check that planned moves never do.
private final class CursorProxy: TextProxy {
    var units: [UInt16]
    var cursor: Int
    var adjustCalls = 0
    init(_ before: String, _ after: String = "") { units = Array((before + after).utf16); cursor = before.utf16.count }
    var contextBefore: String? { cursor == 0 ? nil : String(decoding: units[..<cursor], as: UTF16.self) }
    var contextAfter: String? { cursor == units.count ? nil : String(decoding: units[cursor...], as: UTF16.self) }
    var hasText: Bool { !units.isEmpty }
    func insert(_ t: String) { units.insert(contentsOf: Array(t.utf16), at: cursor); cursor += t.utf16.count }
    func deleteBackwardOnce() {
        guard cursor > 0 else { return }
        let s = String(decoding: units[..<cursor], as: UTF16.self)
        let n = s.last!.utf16.count
        units.removeSubrange((cursor - n)..<cursor); cursor -= n
    }
    func adjustPosition(byUTF16 offset: Int) { adjustCalls += 1; cursor = max(0, min(units.count, cursor + offset)) }
    var before: String { String(decoding: units[..<cursor], as: UTF16.self) }
    var after: String { String(decoding: units[cursor...], as: UTF16.self) }
}

@MainActor
private func coordinator(_ proxy: CursorProxy) -> TypingCoordinator {
    let c = TypingCoordinator(input: InputController(proxy: proxy))
    c.fieldDidChange(FieldConfig())
    return c
}

@Suite struct CursorMathTests {
    private let tricky = ["a", "é", "e\u{301}", "👨‍👩‍👧", "🇮🇳", "👍🏽", "स्ते", "क्षि", "ज़"]

    @Test func graphemeStepsNeverSplitAClusterInEitherDirection() {
        let doc = "x" + tricky.joined(separator: "·") + "y"
        let chars = Array(doc)
        for split in 0...chars.count {
            let before = String(chars[..<split]), after = String(chars[split...])
            for steps in [-3, -1, 1, 3] {
                let off = CursorMath.utf16Offset(graphemes: steps, before: before, after: after)
                let p = CursorProxy(before, after)
                p.adjustPosition(byUTF16: off)
                let target = max(0, min(chars.count, split + steps))
                #expect(p.before == String(chars[..<target]), "split \(split) steps \(steps)")
            }
        }
    }

    @Test func eachClusterIsOneStep() {
        for t in tricky {
            let p = CursorProxy("a" + t)
            p.adjustPosition(byUTF16: CursorMath.utf16Offset(graphemes: -1, before: p.before, after: p.after))
            #expect(p.before == "a", "\(t) \(t.unicodeScalars.map(\.value)) chars=\(t.count)")
            p.adjustPosition(byUTF16: CursorMath.utf16Offset(graphemes: 1, before: p.before, after: p.after))
            #expect(p.before == "a" + t)
        }
    }

    @Test func clampedAtDocumentEdges() {
        #expect(CursorMath.utf16Offset(graphemes: -5, before: "ab", after: "") == -2)
        #expect(CursorMath.utf16Offset(graphemes: 5, before: "", after: "xy") == 2)
        #expect(CursorMath.utf16Offset(graphemes: -1, before: "", after: "") == 0)
        // Right drag at the end of a line (the host's after-context stops before the line break): step over it.
        #expect(CursorMath.utf16Offset(graphemes: 1, before: "ab", after: "", crossingLineEnd: true) == 1)
        #expect(CursorMath.utf16Offset(graphemes: 3, before: "ab", after: "x", crossingLineEnd: true) == 2)
        #expect(CursorMath.utf16Offset(graphemes: 2, before: "ab", after: "xy", crossingLineEnd: true) == 2)
        #expect(CursorMath.utf16Offset(graphemes: 3, before: "ab", after: "x\ny", crossingLineEnd: true) == 3)
        #expect(CursorMath.utf16Offset(graphemes: -1, before: "a\n", after: "", crossingLineEnd: true) == -1)
    }

    @Test func lineJumpsOnlyOnHardBreaksAndKeepColumn() {
        // cursor after "wor" (column 3) on the last line
        var p = CursorProxy("hello\nhi\nwor", "ld")
        p.adjustPosition(byUTF16: CursorMath.lineJumpOffset(up: true, before: p.before, after: p.after)!)
        #expect(p.before == "hello\nhi") // "hi" is shorter: clamps to its end
        p.adjustPosition(byUTF16: CursorMath.lineJumpOffset(up: true, before: p.before, after: p.after)!)
        #expect(p.before == "he") // column 2 of "hi" carries back to "he"
        p = CursorProxy("he", "llo\nhi\nworld")
        p.adjustPosition(byUTF16: CursorMath.lineJumpOffset(up: false, before: p.before, after: p.after)!)
        #expect(p.before == "hello\nhi")
        p.adjustPosition(byUTF16: CursorMath.lineJumpOffset(up: false, before: p.before, after: p.after)!)
        #expect(p.before == "hello\nhi\nwo")
        // no line above / below
        #expect(CursorMath.lineJumpOffset(up: true, before: "single line", after: "") == nil)
        #expect(CursorMath.lineJumpOffset(up: false, before: "a", after: "b c") == nil) // soft wraps are not jumped
    }

    @Test func lineJumpWithEmojiColumns() {
        let p = CursorProxy("a\nx👨‍👩‍👧y", "z")
        // column 3 clusters on the last line; previous line "a" has 1
        p.adjustPosition(byUTF16: CursorMath.lineJumpOffset(up: true, before: p.before, after: p.after)!)
        #expect(p.before == "a")
        p.adjustPosition(byUTF16: CursorMath.lineJumpOffset(up: false, before: p.before, after: p.after)!)
        #expect(p.before == "a\nx")
    }
}

@Suite struct SpacebarCursorDragTests {
    @Test func slowDragMovesOneStepPerStepWidth() {
        var d = SpacebarCursorDrag(start: .zero, time: 0)
        var total = 0
        for i in 1...10 { total += d.move(to: CGPoint(x: CGFloat(i) * 3, y: 0), time: Double(i) * 0.1).horizontal }
        #expect(total == 3) // 30 pt at 9 pt per step, slow (30 pt/s)
    }

    @Test func fastDragMovesFurtherThanSlowDrag() {
        var slow = SpacebarCursorDrag(start: .zero, time: 0), fast = SpacebarCursorDrag(start: .zero, time: 0)
        var s = 0, f = 0
        for i in 1...10 {
            s += slow.move(to: CGPoint(x: CGFloat(i) * 6, y: 0), time: Double(i) * 0.1).horizontal
            f += fast.move(to: CGPoint(x: CGFloat(i) * 6, y: 0), time: Double(i) * 0.01).horizontal
        }
        #expect(f > s)
    }

    @Test func leftIsNegativeAndVerticalProducesLineJumps() {
        var d = SpacebarCursorDrag(start: CGPoint(x: 100, y: 100), time: 0)
        #expect(d.move(to: CGPoint(x: 80, y: 100), time: 0.2).horizontal < 0)
        var e = SpacebarCursorDrag(start: CGPoint(x: 100, y: 100), time: 0)
        var lines = 0
        for i in 1...6 { lines += e.move(to: CGPoint(x: 100, y: 100 - CGFloat(i) * 10), time: Double(i) * 0.1).vertical }
        #expect(lines == -2)
    }
}

@Suite struct BackspaceSwipePlanTests {
    @Test func previewGrowsWithDistanceAndNeverExceedsTheText() {
        let text = "one two three"
        #expect(BackspaceSwipePlan.plan(before: text, extraDistance: 0).preview == "three")
        #expect(BackspaceSwipePlan.plan(before: text, extraDistance: 40).words == 2)
        #expect(BackspaceSwipePlan.plan(before: text, extraDistance: 40).preview == "two three")
        let all = BackspaceSwipePlan.plan(before: text, extraDistance: 1000)
        #expect(all.words == 3)
        #expect(all.graphemes == text.count)
        #expect(BackspaceSwipePlan.plan(before: "", extraDistance: 100).graphemes == 0)
    }

    @Test func emojiAndDevanagariWordsAreWholeClusters() {
        let plan = BackspaceSwipePlan.plan(before: "hi 👨‍👩‍👧 नमस्ते", extraDistance: 40)
        #expect(plan.preview == "👨‍👩‍👧 नमस्ते")
    }
}

@MainActor @Suite struct CoordinatorCursorTests {
    @Test func moveCursorByGraphemesUsesUTF16Offsets() {
        let p = CursorProxy("a👨‍👩‍👧", "🇮🇳z")
        let c = coordinator(p)
        #expect(c.moveCursor(graphemes: -1))
        #expect(p.before == "a")
        #expect(c.moveCursor(graphemes: 2))
        #expect(p.before == "a👨‍👩‍👧🇮🇳")
        #expect(p.adjustCalls == 2)
    }

    @Test func lineJumpMovesThroughCoordinator() {
        let p = CursorProxy("ab\ncd", "\nef")
        let c = coordinator(p)
        #expect(c.moveCursor(lines: -1))
        #expect(p.before == "ab")
        #expect(c.moveCursor(lines: 1))
        #expect(p.before == "ab\ncd")
    }

    @Test func noMoveWhenThereIsNothingToMoveTo() {
        let p = CursorProxy("only", "")
        let c = coordinator(p)
        #expect(!c.moveCursor(lines: 1))
        #expect(p.adjustCalls == 0)
        // A step right at the end of the visible context is attempted (it may cross a line break the host does not
        // show); at the real end of the document the host clamps it to nothing.
        #expect(c.moveCursor(graphemes: 1))
        #expect(p.adjustCalls == 1)
    }

    @Test func rightDragAtTheEndOfALineWrapsDown() {
        // The host shows only the rest of the current line after the cursor (no "\n"), like UITextView does.
        let p = CursorProxy("first", "")
        let c = coordinator(p)
        #expect(c.moveCursor(graphemes: 1))
        #expect(p.adjustCalls == 1)
    }

    @Test func deleteRunRemovesPlannedGraphemes() {
        let p = CursorProxy("keep one 👍🏽 two")
        let c = coordinator(p)
        let plan = BackspaceSwipePlan.plan(before: p.before, extraDistance: 40)
        c.deleteRun(graphemes: plan.graphemes)
        #expect(p.before == "keep one ")
    }
}

@Suite struct KeyFlickTests {
    @Test func upIsNumberOrSymbolDownIsAlternate() {
        #expect(KeyFlick.text(for: .letter("q"), direction: .up, uppercase: false) == "1")
        #expect(KeyFlick.text(for: .letter("P"), direction: .up, uppercase: true) == "0")
        #expect(KeyFlick.text(for: .letter("a"), direction: .down, uppercase: false) == "à")
        #expect(KeyFlick.text(for: .letter("a"), direction: .down, uppercase: true) == "À")
        #expect(KeyFlick.text(for: .letter("q"), direction: .down, uppercase: false) == nil)
        #expect(KeyFlick.text(for: .space, direction: .up, uppercase: false) == nil)
    }

    @Test func everyLetterHasAnUpFlick() {
        for ch in "abcdefghijklmnopqrstuvwxyz" { #expect(KeyFlick.hint(for: .letter(String(ch))) != nil, "\(ch)") }
    }
}

@Suite struct FlickGatingTests {
    let layout = TraceFixtures.layout

    /// A quick vertical flick from the home row up onto the row above crosses a key but must never become a swipe.
    @Test func verticalFlickCrossingAKeyIsNotASwipe() {
        var cap = SwipeCapture()
        var arb = GestureArbiter(start: .letter, origin: TraceFixtures.centre("s"), time: 0, keyHeight: layout.metrics.keyHeight)
        _ = cap.begin(id: 1, at: TraceFixtures.centre("s"), time: 0, layout: layout)
        let s = TraceFixtures.centre("s")
        var update = SwipeCaptureUpdate.none
        let p = CGPoint(x: s.x, y: s.y - layout.metrics.keyHeight * 0.85)
        #expect(layout.hit(at: p)?.keyIndex != layout.hit(at: s)?.keyIndex) // it does enter another key
        _ = arb.move(to: p, time: 0.08, crossedKeys: true)
        update = cap.move(id: 1, to: p, time: 0.08, layout: layout, allowSwipe: arb.decided == .swipeTyping)
        #expect(update == SwipeCaptureUpdate.none)
        #expect(arb.end(at: p, time: 0.1) == .flickUp)
        #expect(cap.end(id: 1, at: p, time: 0.1) == nil)
    }

    @Test func slowOrHorizontalCrossingStillSwipes() {
        var cap = SwipeCapture()
        let a = TraceFixtures.centre("a"), d = TraceFixtures.centre("d")
        var arb = GestureArbiter(start: .letter, origin: a, time: 0, keyHeight: layout.metrics.keyHeight)
        _ = cap.begin(id: 1, at: a, time: 0, layout: layout)
        _ = arb.move(to: d, time: 0.1, crossedKeys: true)
        let u = cap.move(id: 1, to: d, time: 0.1, layout: layout, allowSwipe: arb.decided == .swipeTyping)
        #expect(u == .began)
    }
}
