import Foundation
import Testing
import IBoardEngine
import IBoardOTP
@testable import IBoardUI

private final class DocProxy: TextProxy {
    var units: [UInt16]
    var cursor: Int
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
    func adjustPosition(byUTF16 offset: Int) { cursor = max(0, min(units.count, cursor + offset)) }
    var text: String { String(decoding: units, as: UTF16.self) }
}

private let tricky = ["a", "é", "e\u{301}", "👨‍👩‍👧", "🇮🇳", "👍🏽", "स्ते", "क्षि", "ज़"]

@MainActor @Suite struct VirtualSelectionTests {
    @Test func selectingRightAndLeftTracksTextAndCount() {
        var s = VirtualSelection(before: "hello ", after: "world again")
        let off = s.move(graphemes: 5)
        #expect(off == 5)
        #expect(s.selectedText == "world")
        #expect(s.count == 5)
        #expect(s.banner == "\u{201C}world\u{201D} \u{00B7} 5 chars")
        var l = VirtualSelection(before: "hello ", after: "world")
        #expect(l.move(graphemes: -3) == -3)
        #expect(l.selectedText == "lo ")
        #expect(l.extent == -3)
    }

    @Test func clampsToCapturedContext() {
        var s = VirtualSelection(before: "ab", after: "cd")
        #expect(s.move(graphemes: 10) == 2)
        #expect(s.selectedText == "cd")
        #expect(s.move(graphemes: -10) == -4)
        #expect(s.selectedText == "ab")
    }

    @Test func movesNeverSplitClustersAndCountClusters() {
        let doc = tricky.joined(separator: "·")
        let chars = Array(doc)
        for split in 0...chars.count {
            for steps in [-4, -1, 1, 4] {
                var s = VirtualSelection(before: String(chars[..<split]), after: String(chars[split...]))
                let off = s.move(graphemes: steps)
                let p = DocProxy(String(chars[..<split]), String(chars[split...]))
                p.adjustPosition(byUTF16: off)
                let target = max(0, min(chars.count, split + steps))
                #expect(p.contextBefore ?? "" == String(chars[..<target]), "split \(split) steps \(steps)")
                #expect(s.count == abs(target - split))
            }
        }
    }

    @Test func lineJumpSelectsAcrossLines() {
        var s = VirtualSelection(before: "one\ntwo", after: "\nthree")
        let off = s.move(graphemes: 0, lines: 1)
        let p = DocProxy("one\ntwo", "\nthree")
        p.adjustPosition(byUTF16: off)
        #expect(p.contextBefore == "one\ntwo\nthr")
        #expect(s.selectedText == "\nthr")
        var up = VirtualSelection(before: "one\ntwo", after: "")
        let o2 = up.move(graphemes: 0, lines: -1)
        let p2 = DocProxy("one\ntwo")
        p2.adjustPosition(byUTF16: o2)
        #expect(p2.contextBefore == "one")
        #expect(up.selectedText == "\ntwo")
    }

    private func run(_ action: SelectionAction, _ sel: inout VirtualSelection, _ proxy: DocProxy) -> SelectionEdit? {
        guard let e = sel.edit(for: action) else { return nil }
        let c = TypingCoordinator(input: InputController(proxy: proxy))
        c.fieldDidChange(FieldConfig())
        c.applySelectionEdit(e)
        sel.apply(action, edit: e)
        return e
    }

    @Test func deleteWorksForBothDirectionsWithTrickyText() {
        for dir in [-1, 1] {
            for t in tricky {
                let before = "x" + (dir < 0 ? t : ""), after = (dir < 0 ? "" : t) + "y"
                var sel = VirtualSelection(before: before, after: after)
                let p = DocProxy(before, after)
                let n = t.count
                p.adjustPosition(byUTF16: sel.move(graphemes: dir * n))
                #expect(sel.selectedText == t)
                _ = run(.delete, &sel, p)
                #expect(p.text == "xy", "dir \(dir) \(t)")
                #expect(sel.isEmpty)
            }
        }
    }

    @Test func cutReturnsPasteboardTextAndDeletes() {
        var sel = VirtualSelection(before: "say ", after: "👍🏽 ok")
        let p = DocProxy("say ", "👍🏽 ok")
        p.adjustPosition(byUTF16: sel.move(graphemes: 1))
        let e = run(.cut, &sel, p)
        #expect(e?.pasteboardText == "👍🏽")
        #expect(p.text == "say  ok")
    }

    @Test func copyKeepsSelectionAndNeedsNoEdit() {
        var sel = VirtualSelection(before: "ab", after: "cd")
        _ = sel.move(graphemes: 2)
        let e = sel.edit(for: .copy)
        #expect(e?.pasteboardText == "cd")
        #expect(e?.deleteGraphemes == 0 && e?.endsSelection == false)
        #expect(SelectionAction.cut.needsFullAccess && SelectionAction.copy.needsFullAccess)
        #expect(!SelectionAction.delete.needsFullAccess)
    }

    @Test func caseCyclesAndKeepsTheSelectionAtTheRightEnd() {
        var sel = VirtualSelection(before: "x ", after: "hello world y")
        let p = DocProxy("x ", "hello world y")
        p.adjustPosition(byUTF16: sel.move(graphemes: 11))
        _ = run(.cycleCase, &sel, p)
        #expect(p.text == "x Hello World y")
        #expect(sel.selectedText == "Hello World")
        _ = run(.cycleCase, &sel, p)
        #expect(p.text == "x HELLO WORLD y")
        _ = run(.cycleCase, &sel, p)
        #expect(p.text == "x hello world y")
        #expect(p.contextBefore == "x hello world")
    }

    @Test func caseCycleOnLeftwardSelectionMovesOverIt() {
        var sel = VirtualSelection(before: "a b", after: " c")
        let p = DocProxy("a b", " c")
        p.adjustPosition(byUTF16: sel.move(graphemes: -3))
        let e = run(.cycleCase, &sel, p)
        #expect(e?.moveUTF16 == 3)
        #expect(p.text == "A B c")
        #expect(p.contextBefore == "A B")
    }

    @Test func caseCycleWithoutLettersIsNil() {
        #expect(SelectionCase.cycle("123 !") == nil)
        #expect(SelectionCase.cycle("abc") == "Abc")
        #expect(SelectionCase.cycle("Abc") == "ABC")
        #expect(SelectionCase.cycle("ABC") == "abc")
        #expect(SelectionCase.cycle("aBc") == "abc")
    }

    @Test func emptySelectionHasNoActionsExceptDismiss() {
        let sel = VirtualSelection(before: "a", after: "b")
        for a in [SelectionAction.cut, .copy, .delete, .cycleCase] { #expect(sel.edit(for: a) == nil) }
        #expect(sel.edit(for: .dismiss) != nil)
    }

    @Test func bannerTruncatesAndSingular() {
        #expect(SelectionBanner.text("a", count: 1) == "\u{201C}a\u{201D} \u{00B7} 1 char")
        let long = String(repeating: "abcdefghij", count: 8)
        let b = SelectionBanner.text(long, count: 80)
        #expect(b.contains("\u{2026}") && b.hasSuffix("80 chars") && b.count < 50)
        #expect(!SelectionBanner.text("a\nb", count: 3).contains("\n"))
    }

    @Test func hostSelectionActsWithOneBackspaceAndReinsert() {
        let h = HostSelection(text: "hello")
        #expect(h.banner == "\u{201C}hello\u{201D} \u{00B7} 5 chars")
        #expect(h.edit(for: .delete)?.deleteGraphemes == 1)
        #expect(h.edit(for: .copy)?.pasteboardText == "hello")
        let e = h.edit(for: .cycleCase)
        #expect(e?.insert == "Hello" && e?.deleteGraphemes == 1 && e?.endsSelection == false)
        #expect(h.edit(for: .dismiss)?.deleteGraphemes == 0)
    }
}

