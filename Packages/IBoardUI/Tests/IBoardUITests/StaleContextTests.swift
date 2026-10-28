import CoreGraphics
import Foundation
import Synchronization
import Testing
import IBoardEngine
import IBoardLayout
@testable import IBoardUI

// Fast typing: `documentContextBefore` lags the keystrokes we just inserted (P-24). The coordinator must not make
// spacing / double-space-period / whole-word-backspace decisions from that stale view.

private final class LagProxy: TextProxy {
    var text = ""
    var snapshot = ""
    var lagging = false
    var contextBefore: String? {
        let s = lagging ? snapshot : text
        return s.isEmpty ? nil : s
    }
    var hasText: Bool { !text.isEmpty }
    func insert(_ t: String) { text += t }
    func deleteBackwardOnce() { if !text.isEmpty { text.removeLast() } }
    /// From now on the proxy keeps reporting what the field holds right now.
    func freeze() { snapshot = text; lagging = true }
}

private final class LDecoder: SwipeDecoding {
    let words = Mutex<[String]>([])
    func decode(points: [SwipePoint], previousWords: [String]) async -> SwipeOutcome? {
        SwipeOutcome(words: words.withLock { $0 }, confidence: 0.9)
    }
    func updateLayout(_ layout: KeyboardLayout) async {}
}

@MainActor
private struct LRig {
    let proxy = LagProxy()
    let coordinator: TypingCoordinator
    let layout: KeyboardLayout
    let decoder = LDecoder()
    let points = [SwipePoint(x: 10, y: 10, t: 0), SwipePoint(x: 50, y: 10, t: 0.1), SwipePoint(x: 90, y: 10, t: 0.2)]

    init() {
        layout = LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters)
        coordinator = TypingCoordinator(input: InputController(proxy: proxy))
        coordinator.setLayout(layout)
        coordinator.fieldDidChange(FieldConfig())
        coordinator.setSwipeDecoder(decoder)
    }

    func type(_ s: String) {
        for ch in s {
            let str = String(ch)
            if let k = layout.firstKey(.letter(str)) {
                coordinator.trackTouch(id: 1, at: CGPoint(x: k.frame.midX, y: k.frame.midY))
                coordinator.insert(str)
                coordinator.releaseTouch(id: 1)
            } else {
                coordinator.insert(str)
            }
        }
    }

    func swipe(_ w: String) async {
        decoder.words.withLock { $0 = [w] }
        coordinator.swipeEnded(points: points, shift: .off)
        await coordinator.waitForIdle()
    }
}

@MainActor
@Suite("Stale proxy context")
struct StaleContextTests {
    @Test func doubleSpaceMakesPeriodEvenWhenProxyLags() {
        let r = LRig()
        r.type("hello")
        r.proxy.freeze()
        r.type("  ")
        #expect(r.proxy.text == "hello. ")
    }

    @Test func swipeAfterTypedSpaceDoesNotAddSecondSpace() async {
        let r = LRig()
        r.type("hi")
        r.proxy.freeze()
        r.type(" ")
        await r.swipe("world")
        #expect(r.proxy.text == "hi world ")
    }

    @Test func swipeRightAfterTypedLettersGetsASpace() async {
        let r = LRig()
        r.proxy.freeze() // empty field, proxy has not seen the letter yet
        r.type("a")
        await r.swipe("world")
        #expect(r.proxy.text == "a world ")
    }

    @Test func backspaceRightAfterSwipeRemovesTheWholeWordEvenWhenProxyLags() async {
        let r = LRig()
        r.type("hi ")
        r.proxy.freeze()
        await r.swipe("hello")
        #expect(r.proxy.text == "hi hello ")
        r.coordinator.deleteBackward()
        #expect(r.proxy.text == "hi ")
    }

    @Test func punctuationRightAfterSwipeTakesBackTheSpaceEvenWhenProxyLags() async {
        let r = LRig()
        r.type("hi ")
        r.proxy.freeze()
        await r.swipe("hello")
        r.type(".")
        #expect(r.proxy.text == "hi hello.")
    }

    @Test func autoShiftSeesTheSentenceEndWhenProxyLags() {
        let r = LRig()
        r.type("done")
        r.proxy.freeze()
        r.type(". ")
        #expect(r.coordinator.autoShift(context: r.proxy.contextBefore) == .once)
    }
}
