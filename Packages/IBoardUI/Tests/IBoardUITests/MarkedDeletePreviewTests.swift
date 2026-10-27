import Foundation
import Testing
@testable import IBoardUI

/// A host text field that models marked text: `marked` is the tail range of `text` currently marked.
private final class MarkedHost: TextProxy {
    var text: String
    var markedLength = 0
    let supportsMarked: Bool
    init(_ t: String, supportsMarked: Bool = true) { text = t; self.supportsMarked = supportsMarked }
    var contextBefore: String? { text.isEmpty ? nil : text }
    var hasText: Bool { !text.isEmpty }
    func insert(_ t: String) { markedLength = 0; text += t }
    func deleteBackwardOnce() { if !text.isEmpty { text.removeLast() } }
    func setMarkedText(_ t: String) {
        guard supportsMarked else { return } // ignored by the host: the text just is not there
        text.removeLast(markedLength)
        text += t
        markedLength = t.count
    }
    func unmarkText() { markedLength = 0 }
}

@MainActor
@Suite("Backspace swipe in-field preview")
struct MarkedDeletePreviewTests {
    private func plan(_ before: String, _ extra: CGFloat) -> BackspaceSwipePlan {
        BackspaceSwipePlan.plan(before: before, extraDistance: extra)
    }

    @Test func showKeepsTheTextVisibleAsMarkedTail() {
        let host = MarkedHost("hello big world")
        let p = MarkedDeletePreview(proxy: host)
        p.show(plan("hello big world", 0))
        #expect(host.text == "hello big world")
        #expect(host.markedLength == "world".count)
        #expect(p.verify())
    }

    @Test func growingAndShrinkingThePlanRedoesTheMark() {
        let host = MarkedHost("one two three")
        let p = MarkedDeletePreview(proxy: host)
        let base = "one two three"
        p.show(plan(base, 0))
        p.show(plan(base, 40)) // two words
        #expect(host.text == base)
        #expect(host.markedLength == "two three".count)
        p.show(plan(base, 0)) // back to one word
        #expect(host.text == base)
        #expect(host.markedLength == "three".count)
    }

    @Test func commitDeletesExactlyTheMarkedWords() {
        let host = MarkedHost("one two three")
        let p = MarkedDeletePreview(proxy: host)
        p.show(plan("one two three", 40))
        #expect(p.commit() == "two three".count)
        #expect(host.text == "one ")
        #expect(!p.isActive)
    }

    @Test func cancelLeavesTheTextUntouched() {
        let host = MarkedHost("one two three")
        let p = MarkedDeletePreview(proxy: host)
        p.show(plan("one two three", 40))
        p.cancel()
        #expect(host.text == "one two three")
        #expect(host.markedLength == 0)
    }

    @Test func hostWithoutMarkedTextSupportNeverLosesText() {
        let host = MarkedHost("one two three", supportsMarked: false)
        let p = MarkedDeletePreview(proxy: host)
        p.show(plan("one two three", 0))
        #expect(host.text == "one two ") // the host ignored the marked text: the words are gone for now
        #expect(!p.verify())               // detected: re-inserted as plain text
        #expect(host.text == "one two three")
        #expect(!p.isActive)
    }

    @Test func cancelOnAnUnsupportingHostRestoresTheWords() {
        let host = MarkedHost("alpha beta", supportsMarked: false)
        let p = MarkedDeletePreview(proxy: host)
        p.show(plan("alpha beta", 0))
        p.cancel()
        #expect(host.text == "alpha beta")
    }

    @Test func emojiAreDeletedAsWholeGraphemes() {
        let host = MarkedHost("hi 👍🏽")
        let p = MarkedDeletePreview(proxy: host)
        p.show(plan("hi 👍🏽", 0))
        #expect(p.commit() == "👍🏽".count)
        #expect(host.text == "hi ")
    }

    @Test func emptyPlanDoesNothing() {
        let host = MarkedHost("")
        let p = MarkedDeletePreview(proxy: host)
        p.show(plan("", 0))
        #expect(!p.isActive)
        #expect(p.commit() == 0)
    }
}

@MainActor
@Suite("Backspace swipe live preview")
struct LiveDeletePreviewTests {
    private func plan(_ before: String, _ extra: CGFloat) -> BackspaceSwipePlan {
        BackspaceSwipePlan.plan(before: before, extraDistance: extra)
    }

    @Test func wordsVanishWhileDraggingAndReturnWhenDraggedBack() {
        let base = "one two three"
        let host = MarkedHost(base)
        let p = MarkedDeletePreview(proxy: host, style: .live)
        p.show(plan(base, 0))
        #expect(host.text == "one two ")
        p.show(plan(base, 40))
        #expect(host.text == "one ")
        p.show(plan(base, 0)) // dragged back by a word
        #expect(host.text == "one two ")
        p.show(plan(base, 0))
        #expect(host.text == "one two ")
    }

    @Test func commitKeepsTheDeletionCancelRestoresEverything() {
        let base = "alpha beta gamma"
        let a = MarkedHost(base)
        let pa = MarkedDeletePreview(proxy: a, style: .live)
        pa.show(plan(base, 40))
        #expect(a.text == "alpha ")
        #expect(pa.commit() == "beta gamma".count)
        #expect(a.text == "alpha ")

        let b = MarkedHost(base)
        let pb = MarkedDeletePreview(proxy: b, style: .live)
        pb.show(plan(base, 40))
        pb.cancel()
        #expect(b.text == base)
    }

    @Test func liveModeWorksInHostsThatIgnoreMarkedText() {
        let base = "one two three"
        let host = MarkedHost(base, supportsMarked: false)
        let p = MarkedDeletePreview(proxy: host, style: .live)
        p.show(plan(base, 0))
        #expect(p.verify())
        p.cancel()
        #expect(host.text == base)
    }
}
