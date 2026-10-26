import CoreGraphics
import Foundation
import Synchronization
import Testing
import IBoardEngine
import IBoardLayout
@testable import IBoardUI

private final class SProxy: TextProxy {
    var text = ""
    var contextBefore: String? { text }
    var hasText: Bool { !text.isEmpty }
    func insert(_ t: String) { text += t }
    func deleteBackwardOnce() { if !text.isEmpty { text.removeLast() } }
}

private final class SDecoder: SwipeDecoding {
    let outcome = Mutex<SwipeOutcome?>(nil)
    let seen = Mutex<[[String]]>([])
    func set(_ o: SwipeOutcome?) { outcome.withLock { $0 = o } }
    func decode(points: [SwipePoint], previousWords: [String]) async -> SwipeOutcome? {
        seen.withLock { $0.append(previousWords) }
        return outcome.withLock { $0 }
    }
    func updateLayout(_ layout: KeyboardLayout) async {}
}

private enum LEvent: Equatable, Sendable { case committed(String, CommitSource), reopened, continued, other }

private final class SLearner: PersonalLearning {
    let events = Mutex<[LEvent]>([])
    var log: [LEvent] { events.withLock { $0 } }
    func add(_ e: LEvent) { events.withLock { $0.append(e) } }
    func setIncognito(_ on: Bool) async {}
    func fieldDidChange(_ traits: FieldTraits) async {}
    func wordCommitted(_ word: String, source: CommitSource) async { add(.committed(word, source)) }
    func typingContinued() async { add(.continued) }
    func lastWordReopened() async { add(.reopened) }
    func autocorrectReverted(original: String) async {}
    func sentenceBoundary() async { add(.other) }
    func flush() async {}
}

@MainActor
private struct SRig {
    let proxy = SProxy()
    let coordinator: TypingCoordinator
    let decoder = SDecoder()
    let learner = SLearner()
    let points = [SwipePoint(x: 10, y: 10, t: 0), SwipePoint(x: 50, y: 10, t: 0.1), SwipePoint(x: 90, y: 10, t: 0.2)]

    init(config: FieldConfig = FieldConfig()) {
        let layout = LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters)
        coordinator = TypingCoordinator(input: InputController(proxy: proxy))
        coordinator.setLayout(layout)
        coordinator.fieldDidChange(config)
        coordinator.setSwipeDecoder(decoder)
        coordinator.setLearner(learner)
    }

    func swipe(_ words: [String], shift: ShiftState = .off) async {
        decoder.set(SwipeOutcome(words: words, confidence: 0.9))
        coordinator.swipeEnded(points: points, shift: shift)
        await coordinator.waitForIdle()
    }

    func tap(_ s: String) async {
        coordinator.insert(s)
        await coordinator.waitForIdle()
    }
}

@MainActor
@Suite("Swipe typing coordinator")
struct SwipeCoordinatorTests {
    @Test func firstSwipeInsertsWordWithImpliedSpaceAfter() async {
        let r = SRig()
        await r.swipe(["hello", "hells", "jello"])
        #expect(r.proxy.text == "hello ")
        #expect(r.coordinator.lastSwipedWord == "hello")
    }

    @Test func secondSwipeNeedsNoExtraSpace() async {
        let r = SRig()
        await r.swipe(["hello"])
        await r.swipe(["world"])
        #expect(r.proxy.text == "hello world ")
    }

    @Test func autoSpaceAfterTypedLetterButNotAfterOpeners() async {
        let r = SRig()
        await r.tap("a")
        await r.swipe(["cat"])
        #expect(r.proxy.text == "a cat ")
        let r2 = SRig()
        r2.proxy.text = "("
        await r2.swipe(["cat"])
        #expect(r2.proxy.text == "(cat ")
        let r3 = SRig()
        r3.proxy.text = "end. "
        await r3.swipe(["cat"])
        #expect(r3.proxy.text == "end. cat ")
    }

    @Test func spaceNeededAfterPunctuationAndDigits() {
        #expect(SwipeSpacing.needsSpace(before: "end."))
        #expect(SwipeSpacing.needsSpace(before: "w2"))
        #expect(!SwipeSpacing.needsSpace(before: nil))
        #expect(!SwipeSpacing.needsSpace(before: ""))
        #expect(!SwipeSpacing.needsSpace(before: "line\n"))
        #expect(!SwipeSpacing.needsSpace(before: "a/"))
    }

    @Test func shiftCapitalisesFirstLetterOrAll() async {
        let r = SRig()
        await r.swipe(["hello", "hells"], shift: .once)
        #expect(r.proxy.text == "Hello ")
        #expect(r.coordinator.content.texts.contains("Hells"))
        let r2 = SRig()
        await r2.swipe(["hello"], shift: .capsLock)
        #expect(r2.proxy.text == "HELLO ")
    }

    @Test func backspaceRightAfterSwipeDeletesWholeWord() async {
        let r = SRig()
        await r.swipe(["hello"])
        await r.swipe(["world"])
        r.coordinator.deleteBackward()
        await r.coordinator.waitForIdle()
        #expect(r.proxy.text == "hello ")
        // The next backspace is an ordinary character delete (the word before was swiped too, but the chain ended).
        r.coordinator.deleteBackward()
        #expect(r.proxy.text == "hello")
        #expect(r.learner.log.contains(.reopened))
    }

    @Test func backspaceAfterTypingIsOrdinary() async {
        let r = SRig()
        await r.swipe(["hello"])
        await r.tap("a")
        r.coordinator.deleteBackward()
        #expect(r.proxy.text == "hello ")
    }

    @Test func stripShowsAlternativesAndTapReplacesWord() async {
        let r = SRig()
        await r.swipe(["hello", "hells", "jello"])
        // Best in the middle.
        #expect(r.coordinator.content.texts == ["hells", "hello", "jello"])
        r.coordinator.tapSlot(2)
        await r.coordinator.waitForIdle()
        #expect(r.proxy.text == "jello ")
        #expect(r.coordinator.lastSwipedWord == "jello")
        let log = r.learner.log
        #expect(log.contains(.committed("hello", .swipe)))
        #expect(log.contains(.reopened))
        #expect(log.contains(.committed("jello", .suggestionTapped)))
        // The replaced word is still one unit for backspace.
        r.coordinator.deleteBackward()
        #expect(r.proxy.text == "")
    }

    @Test func tappingTheBestSlotKeepsTheWord() async {
        let r = SRig()
        await r.swipe(["hello", "hells"])
        r.coordinator.tapSlot(1)
        await r.coordinator.waitForIdle()
        #expect(r.proxy.text == "hello ")
    }

    @Test func punctuationAfterSwipeTakesBackTheSpace() async {
        let r = SRig()
        await r.swipe(["hello"])
        await r.tap(".")
        #expect(r.proxy.text == "hello.")
    }

    @Test func swipedWordIsLearnedViaSwipeSource() async {
        let r = SRig()
        await r.swipe(["hello"])
        await r.tap("a")
        #expect(r.learner.log == [.committed("hello", .swipe), .continued])
    }

    @Test func previousWordsAreContextForTheDecoder() async {
        let r = SRig()
        await r.swipe(["hello"])
        await r.swipe(["world"])
        let seen = r.decoder.seen.withLock { $0 }
        #expect(seen == [[], ["hello"]])
    }

    @Test func hostIsToldWhenTheDecodedWordLands() async {
        let r = SRig()
        var calls = 0
        r.coordinator.onAsyncEdit = { calls += 1 }
        await r.swipe(["hello"])
        #expect(calls == 1)
    }

    @Test func noMatchInsertsNothing() async {
        let r = SRig()
        r.decoder.set(nil)
        r.coordinator.swipeEnded(points: r.points, shift: .off)
        await r.coordinator.waitForIdle()
        #expect(r.proxy.text == "")
        #expect(!r.coordinator.isSwipePending)
    }

    @Test func secureFieldsDoNotSwipe() async {
        let r = SRig(config: FieldConfig(learning: FieldTraits(isSecureTextEntry: true)))
        await r.swipe(["hello"])
        #expect(r.proxy.text == "")
    }

    @Test func currentTypedWordIsEndedLiterallyBeforeTheSwipe() async {
        let r = SRig()
        await r.tap("t")
        await r.tap("h")
        await r.swipe(["cat"])
        #expect(r.proxy.text == "th cat ")
        #expect(r.learner.log.contains(.committed("th", .typed)))
    }

    @Test func inputWhileDecodingIsReplayedInOrder() async {
        let r = SRig()
        r.decoder.set(SwipeOutcome(words: ["hello"]))
        r.coordinator.swipeEnded(points: r.points, shift: .off)
        #expect(r.coordinator.isSwipePending)
        r.coordinator.insert("a") // arrives before the decoder answered
        await r.coordinator.waitForIdle()
        await r.coordinator.waitForIdle()
        #expect(r.proxy.text == "hello a")
    }
}
