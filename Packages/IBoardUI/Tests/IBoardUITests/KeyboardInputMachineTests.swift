import CoreGraphics
import Foundation
import Testing
import IBoardLayout
@testable import IBoardUI

private func makeLayout(_ kind: LayoutKind = .letters, globe: Bool = false) -> KeyboardLayout {
    LayoutEngine.layout(
        containerSize: CGSize(width: 390, height: 260),
        traits: LayoutTraits(needsInputModeSwitchKey: globe), kind: kind
    )
}

// Closure-based emit needs a mutable sink; keep the tests simple with a class sink.
private final class Sink {
    var events: [KeyEvent] = []
    func callAsFunction(_ e: KeyEvent) { events.append(e) }
    var inserts: [String] { events.compactMap { if case .insert(let s) = $0 { s } else { nil } } }
    var nonHighlight: [KeyEvent] { events.filter { if case .highlight = $0 { false } else { true } } }
    func reset() { events.removeAll() }
}

private struct Driver {
    var m: KeyboardInputMachine
    let sink = Sink()
    init(_ layout: KeyboardLayout = makeLayout(), shift: ShiftState = .off) {
        m = KeyboardInputMachine(layout: layout, shift: shift)
    }
    func point(_ id: KeyIdentity) -> CGPoint {
        let f = m.layout.firstKey(id)!.frame
        return CGPoint(x: f.midX, y: f.midY)
    }
    mutating func down(_ touch: Int, _ id: KeyIdentity, t: TimeInterval = 0) {
        let s = sink
        m.touchDown(id: touch, at: point(id), time: t) { s($0) }
    }
    mutating func up(_ touch: Int, t: TimeInterval = 0) {
        let s = sink
        m.touchUp(id: touch, time: t) { s($0) }
    }
    mutating func tap(_ id: KeyIdentity, touch: Int = 1, t: TimeInterval = 0) {
        down(touch, id, t: t); up(touch, t: t + 0.05)
    }
    mutating func tick(_ t: TimeInterval) {
        let s = sink
        m.tick(now: t) { s($0) }
    }
}

@Test func tapInsertsOnTouchUpNotDown() {
    var d = Driver()
    d.down(1, .letter("a"))
    #expect(d.sink.inserts.isEmpty)
    #expect(d.sink.events == [.highlight(keyIndex: d.m.layout.firstKey(.letter("a"))!.id, isOn: true)])
    d.up(1)
    #expect(d.sink.inserts == ["a"])
    #expect(d.m.activeTouchCount == 0)
}

@Test func highlightOnAndOffBalanced() {
    var d = Driver()
    d.tap(.letter("q")); d.tap(.space); d.tap(.letter("m"))
    var on = 0
    for e in d.sink.events { if case .highlight(_, let isOn) = e { on += isOn ? 1 : -1 } }
    #expect(on == 0)
}

@Test func slideChangesKeyAndInsertsFinalKey() {
    var d = Driver()
    d.down(1, .letter("q"))
    let s = d.sink
    d.m.touchMoved(id: 1, to: d.point(.letter("w"))) { s($0) }
    d.up(1)
    #expect(d.sink.inserts == ["w"])
}

@Test func releaseOutsideKeyAreaStillInsertsNearestKey() {
    var d = Driver()
    d.down(1, .letter("a"))
    let s = d.sink
    d.m.touchMoved(id: 1, to: CGPoint(x: 200, y: 500)) { s($0) } // far below the keyboard: nearest key is space
    d.up(1)
    #expect(d.sink.inserts == [" "])
}

@Test func touchInStripIsIgnored() {
    var d = Driver()
    let s = d.sink
    d.m.touchDown(id: 1, at: CGPoint(x: 100, y: 10), time: 0) { s($0) }
    #expect(d.sink.events.isEmpty)
    #expect(d.m.activeTouchCount == 0)
}

@Test func rolloverKeepsTypedOrder() {
    var d = Driver()
    // h down, e down (h still held), i down (e still held), then ups in a scrambled order.
    d.down(1, .letter("h"), t: 0.00)
    d.down(2, .letter("e"), t: 0.03)
    #expect(d.sink.inserts == ["h"]) // h is committed when e goes down
    d.down(3, .letter("i"), t: 0.06)
    #expect(d.sink.inserts == ["h", "e"])
    d.up(2, t: 0.08)
    d.up(1, t: 0.09)
    d.up(3, t: 0.10)
    #expect(d.sink.inserts == ["h", "e", "i"]) // no duplicates, no reordering
    #expect(d.m.activeTouchCount == 0)
}

@Test func rolloverNeverDropsOrDuplicatesAcrossManyOverlaps() {
    var d = Driver()
    let letters = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    for (i, l) in letters.enumerated() {
        d.down(i + 1, .letter(l), t: Double(i) * 0.02)
        if i >= 4 { d.up(i - 3) } // at most 5 fingers overlap, released out of lockstep
    }
    for i in (letters.count - 3)...letters.count { d.up(i) }
    #expect(d.sink.inserts == letters)
}

@Test func moreTouchesThanSlotsAreIgnoredSafely() {
    var d = Driver()
    let letters = ["q", "w", "e", "r", "t", "y", "u", "i"]
    for (i, l) in letters.enumerated() { d.down(i + 1, .letter(l)) }
    #expect(d.m.activeTouchCount == KeyboardInputMachine.maxTouches)
    for i in 0..<letters.count { d.up(i + 1) }
    #expect(d.sink.inserts == Array(letters.prefix(KeyboardInputMachine.maxTouches)))
}

@Test func shiftOnceThenLetterThenOff() {
    var d = Driver()
    d.tap(.shift, t: 0)
    #expect(d.m.shift == .once)
    d.tap(.letter("a"), touch: 2, t: 1)
    #expect(d.sink.inserts == ["A"])
    #expect(d.m.shift == .off)
    d.tap(.letter("b"), touch: 3, t: 2)
    #expect(d.sink.inserts == ["A", "b"])
}

@Test func shiftTapTwiceQuicklyIsCapsLockAndStays() {
    var d = Driver()
    d.tap(.shift, touch: 1, t: 0)
    d.tap(.shift, touch: 2, t: 0.2)
    #expect(d.m.shift == .capsLock)
    d.tap(.letter("a"), touch: 3, t: 1)
    d.tap(.letter("b"), touch: 4, t: 1.2)
    #expect(d.sink.inserts == ["A", "B"])
    #expect(d.m.shift == .capsLock)
    d.tap(.shift, touch: 5, t: 2)
    #expect(d.m.shift == .off)
}

@Test func shiftTwoSlowTapsTurnsItBackOff() {
    var d = Driver()
    d.tap(.shift, touch: 1, t: 0)
    d.tap(.shift, touch: 2, t: 0.8)
    #expect(d.m.shift == .off)
}

@Test func doubleTapWhileAutoCapitalisedLocksCaps() {
    var d = Driver(shift: .once) // sentence start: auto-capitalisation already set shift
    d.tap(.shift, touch: 1, t: 0)
    #expect(d.m.shift == .off)
    d.tap(.shift, touch: 2, t: 0.25)
    #expect(d.m.shift == .capsLock)
}

@Test func holdingShiftCapitalisesLettersTypedMeanwhile() {
    var d = Driver()
    d.down(1, .shift, t: 0)
    d.tap(.letter("a"), touch: 2, t: 0.3)
    d.tap(.letter("b"), touch: 3, t: 0.5)
    #expect(d.sink.inserts == ["A", "B"])
    d.up(1, t: 0.8)
    d.tap(.letter("c"), touch: 4, t: 1.5)
    #expect(d.sink.inserts == ["A", "B", "c"])
    #expect(d.m.shift == .off)
}

@Test func holdingShiftOnAutoCapitalisedStartStillCapitalises() {
    var d = Driver(shift: .once)
    d.down(1, .shift, t: 0) // toggles auto shift off, but the key is held
    d.tap(.letter("h"), touch: 2, t: 0.3)
    d.up(1, t: 0.6)
    d.tap(.letter("i"), touch: 3, t: 1)
    #expect(d.sink.inserts == ["H", "i"])
}

@Test func shiftHeldWithLetterIsNotADoubleTapForCapsLock() {
    var d = Driver()
    d.down(1, .shift, t: 0)
    d.tap(.letter("a"), touch: 2, t: 0.1)
    d.up(1, t: 0.2)
    d.tap(.shift, touch: 3, t: 0.3)
    #expect(d.m.shift == .once)
}

@Test func externalShiftIsAppliedAndReported() {
    var d = Driver()
    let s = d.sink
    d.m.setShift(.once) { s($0) }
    #expect(d.sink.events == [.shiftChanged(.once)])
    d.tap(.letter("i"))
    #expect(d.sink.inserts == ["I"])
}

@Test func symbolsAreNotUppercasedByCapsLock() {
    var d = Driver(makeLayout(.numbers), shift: .capsLock)
    d.tap(.symbol("1"))
    #expect(d.sink.inserts == ["1"])
}

@Test func layerSwitchOnTouchDownAndReportedOnce() {
    var d = Driver()
    d.down(1, .layerSwitch(.numbers))
    #expect(d.sink.nonHighlight == [.layerChanged(.numbers)])
    #expect(d.m.kind == .numbers)
    d.up(1)
    #expect(d.sink.nonHighlight == [.layerChanged(.numbers)]) // release adds nothing
    // Host swaps layout; "#+=" then "ABC" round trip.
    d.m.setLayout(makeLayout(.numbers))
    d.tap(.layerSwitch(.symbols), touch: 2)
    d.m.setLayout(makeLayout(.symbols))
    d.tap(.layerSwitch(.numbers), touch: 3)
    d.m.setLayout(makeLayout(.numbers))
    d.tap(.layerSwitch(.letters), touch: 4)
    #expect(d.sink.nonHighlight == [.layerChanged(.numbers), .layerChanged(.symbols),
                                    .layerChanged(.numbers), .layerChanged(.letters)])
}

@Test func layerSwitchWhileOtherFingerHeldEndsItsHighlightAndDoesNotInsertOnOldLayout() {
    var d = Driver()
    d.down(1, .letter("a"), t: 0)
    d.down(2, .layerSwitch(.numbers), t: 0.02)
    // The held "a" is committed in order before the switch (rollover), then the layer changes.
    #expect(d.sink.nonHighlight == [.insert("a"), .layerChanged(.numbers)])
    d.m.setLayout(makeLayout(.numbers))
    d.up(1); d.up(2)
    #expect(d.sink.inserts == ["a"])
    #expect(d.m.activeTouchCount == 0)
}

@Test func deleteActsOnDownThenRepeatsAfterDelay() {
    var d = Driver()
    d.down(1, .delete, t: 0)
    #expect(d.sink.nonHighlight == [.deleteBackward])
    #expect(d.m.nextDeadline == 0.5)
    d.tick(0.4)
    #expect(d.sink.nonHighlight.count == 1)
    d.tick(0.5)
    #expect(d.sink.nonHighlight.count == 2)
    d.tick(0.6)
    #expect(d.sink.nonHighlight.count == 3)
    d.up(1, t: 0.65)
    #expect(d.m.nextDeadline == nil)
    d.tick(5)
    #expect(d.sink.nonHighlight.count == 3)
}

@Test func deleteAcceleratesThenSwitchesToWords() throws {
    var d = Driver()
    d.down(1, .delete, t: 0)
    d.sink.reset()
    var t = 0.0
    var chars = 0, words = 0
    var firstWordTime: TimeInterval?
    var countsAt: [Int] = []
    while t < 3.5 {
        t += 0.01
        let before = d.sink.events.count
        d.tick(t)
        for e in d.sink.events[before...] {
            if e == .deleteBackward { chars += 1 }
            if e == .deleteWord { words += 1; firstWordTime = firstWordTime ?? t }
        }
        if abs(t - 1.0) < 0.005 || abs(t - 2.0) < 0.005 { countsAt.append(chars) }
    }
    #expect(words > 0)
    #expect(try #require(firstWordTime) >= 2.0)
    // Chars between 0.5 and 1.0 s at 0.1 s intervals, then twice as fast until 2.0 s.
    #expect(countsAt.count == 2)
    let firstSecond = countsAt[0], secondSecond = countsAt[1] - countsAt[0]
    #expect(secondSecond > firstSecond)
}

@Test func lateTickIsCappedNotFlooded() {
    var d = Driver()
    d.down(1, .delete, t: 0)
    d.sink.reset()
    d.tick(10)
    #expect(d.sink.events.count <= d.m.deletePolicy.maxCatchUp)
}

@Test func deleteCancelStopsRepeat() {
    var d = Driver()
    d.down(1, .delete, t: 0)
    let s = d.sink
    d.m.touchCancelled(id: 1) { s($0) }
    #expect(d.m.nextDeadline == nil)
    #expect(d.m.activeTouchCount == 0)
}

@Test func typingWhileDeleteHeldKeepsRepeating() {
    var d = Driver()
    d.down(1, .delete, t: 0)
    d.tap(.letter("a"), touch: 2, t: 0.1)
    #expect(d.m.nextDeadline != nil)
    d.tick(0.5)
    #expect(d.sink.nonHighlight == [.deleteBackward, .insert("a"), .deleteBackward])
}

@Test func returnAndGlobeFireOnTouchUp() {
    var d = Driver(makeLayout(.letters, globe: true))
    d.down(1, .returnKey(.default))
    #expect(d.sink.nonHighlight.isEmpty)
    d.up(1)
    d.tap(.globe, touch: 2)
    #expect(d.sink.nonHighlight == [.returnKey, .advanceKeyboard])
}

@Test func cancelAllReleasesEverythingWithoutActions() {
    var d = Driver()
    d.down(1, .letter("a")); d.down(2, .delete)
    d.sink.reset()
    let s = d.sink
    d.m.cancelAll { s($0) }
    #expect(d.m.activeTouchCount == 0)
    #expect(d.m.nextDeadline == nil)
    #expect(d.sink.nonHighlight.isEmpty)
}

@Test func duplicateDownForSameIDIsTreatedAsMissedCancel() {
    var d = Driver()
    d.down(1, .letter("a"))
    d.down(1, .letter("b"))
    d.up(1)
    #expect(d.sink.inserts == ["b"])
}

@Test func rotationLayoutSwapKeepsMatchingKeyAndDropsOthers() {
    var d = Driver()
    d.down(1, .letter("a"))
    d.m.setLayout(LayoutEngine.layout(containerSize: CGSize(width: 430, height: 270), traits: LayoutTraits(), kind: .letters))
    d.up(1)
    #expect(d.sink.inserts == ["a"])
    d.down(2, .letter("a"))
    d.m.setLayout(makeLayout(.numbers))
    d.up(2)
    #expect(d.sink.inserts == ["a"]) // slot dropped by the layer change, no insert
}

@Test func wordDeleteCounts() {
    #expect(wordDeleteCount(before: "") == 0)
    #expect(wordDeleteCount(before: "hello") == 5)
    #expect(wordDeleteCount(before: "hello world") == 5)
    #expect(wordDeleteCount(before: "hello world  ") == 7)
    #expect(wordDeleteCount(before: "a\nb") == 1)
    #expect(wordDeleteCount(before: "   ") == 3)
    #expect(wordDeleteCount(before: "hi 👍🏽 ") == 2) // a grapheme cluster counts once
}

@Test func slidingFromThe123KeyTypesTheKeyAndReturnsToLetters() {
    var d = Driver()
    let sink = d.sink
    d.down(1, .layerSwitch(.numbers))
    #expect(d.m.kind == .numbers)
    // The host swaps in the numbers layout; the finger slides to the "5" key and lifts.
    d.m.setLayout(makeLayout(.numbers))
    let five = d.point(.symbol("5"))
    d.m.touchUp(id: 1, at: five, time: 0.4) { sink($0) }
    #expect(d.sink.inserts == ["5"])
    #expect(d.m.kind == .letters)
    #expect(d.sink.events.contains(.layerChanged(.letters)))
}

@Test func liftingOnTheLayerKeyItselfStaysOnNumbers() {
    var d = Driver()
    let sink = d.sink
    d.down(1, .layerSwitch(.numbers))
    d.m.setLayout(makeLayout(.numbers))
    d.m.touchUp(id: 1, at: d.point(.layerSwitch(.letters)), time: 0.4) { sink($0) }
    #expect(d.m.kind == .numbers)
    #expect(d.sink.inserts.isEmpty)
}

@Test func emojiKeyOpensTheEmojiPanelOnTouchUp() {
    var d = Driver(LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters,
                                       settings: LayoutSettings(emojiKey: true)))
    d.down(1, .emoji)
    #expect(d.sink.nonHighlight.isEmpty)
    d.up(1)
    #expect(d.sink.nonHighlight == [.openEmoji])
}
