import CoreGraphics
import Foundation
import Testing
import IBoardEngine
import IBoardLayout
@testable import IBoardUI

fileprivate struct Sample { var x: Double; var y: Double; var t: Double }

private func fixtureURL(_ file: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("IBoardEngine/Tests/IBoardEngineTests/Fixtures/small/\(file)")
}

/// Runs a recorded trace through the arbiter the way the keyboard would: the layout decides the start kind and
/// whether a sample is over another letter key.
fileprivate struct Replay {
    let layout = TraceFixtures.layout
    var keyHeight: CGFloat { layout.firstKey(.letter("a"))!.frame.height }

    func startKind(at p: CGPoint) -> GestureStart {
        guard let h = layout.hit(at: p) else { return .other }
        switch layout.keys[h.keyIndex].identity {
        case .letter: return .letter
        case .space: return .space
        case .delete: return .delete
        default: return .other
        }
    }

    /// `ticks`: also call `tick(now:)` at every sample time (a host display link).
    func run(_ s: [Sample], shift: Bool = false, likelyWord: Bool = false, ticks: Bool = true,
             thresholds: GestureThresholds = GestureThresholds()) -> (final: Gesture, early: [Gesture]) {
        let first = CGPoint(x: s[0].x, y: s[0].y)
        let kind = startKind(at: first)
        let startKey = layout.hit(at: first)?.keyIndex ?? -1
        var arb = GestureArbiter(start: kind, origin: first, time: s[0].t, keyHeight: keyHeight, shiftArmed: shift, thresholds: thresholds)
        var early: [Gesture] = []
        for x in s.dropFirst().dropLast() {
            let p = CGPoint(x: x.x, y: x.y)
            if ticks, let g = arb.tick(now: x.t) { early.append(g) }
            let hit = layout.hit(at: p)?.keyIndex
            var crossed = false
            if let hit, hit != startKey, case .letter = layout.keys[hit].identity { crossed = true }
            if let g = arb.move(to: p, time: x.t, crossedKeys: crossed) { early.append(g) }
        }
        let l = s[s.count - 1]
        let p = CGPoint(x: l.x, y: l.y)
        if ticks, let g = arb.tick(now: l.t) { early.append(g) }
        let overKeys = layout.hit(at: p) != nil
        return (arb.end(at: p, time: l.t, endedOverKeys: overKeys, likelyWord: likelyWord), early)
    }

    func line(from a: CGPoint, to b: CGPoint, duration: Double, steps: Int = 12, t0: Double = 0) -> [Sample] {
        (0...steps).map { i in
            let f = Double(i) / Double(steps)
            return Sample(x: Double(a.x) + Double(b.x - a.x) * f, y: Double(a.y) + Double(b.y - a.y) * f, t: t0 + duration * f)
        }
    }

    func centre(_ id: KeyIdentity) -> CGPoint {
        let f = layout.firstKey(id)!.frame
        return CGPoint(x: f.midX, y: f.midY)
    }
}

@Suite("Gesture arbiter (F5 matrix)")
struct GestureArbiterTests {
    fileprivate let r = Replay()
    var g: CGPoint { r.centre(.letter("g")) }

    // MARK: Letter key

    @Test func tapIsShortAndStill() {
        let s = [Sample(x: g.x, y: g.y, t: 0), Sample(x: g.x + 2, y: g.y + 1, t: 0.05), Sample(x: g.x + 3, y: g.y, t: 0.09)]
        #expect(r.run(s).final == .tap)
    }

    @Test func tapWithSlideInsideTheKeyIsStillATap() {
        let s = r.line(from: g, to: CGPoint(x: g.x + 6, y: g.y), duration: 0.4)
        #expect(r.run(s, ticks: false).final == .tap)
    }

    @Test func longPressFiresAtTheDelayWithoutMovement() {
        var arb = GestureArbiter(start: .letter, origin: g, time: 10, keyHeight: 43)
        #expect(arb.tick(now: 10.34) == nil)
        #expect(arb.tick(now: 10.351) == .longPress)
        #expect(arb.end(at: g, time: 10.5) == .longPress)
    }

    @Test func longPressNeedsAlternatesAndStillness() {
        var noAlt = GestureArbiter(start: .letter, origin: g, time: 0, keyHeight: 43, hasAlternates: false)
        #expect(noAlt.tick(now: 1) == nil)
        var moved = GestureArbiter(start: .letter, origin: g, time: 0, keyHeight: 43)
        _ = moved.move(to: CGPoint(x: g.x + 11, y: g.y), time: 0.2, crossedKeys: false)
        #expect(moved.tick(now: 0.5) == nil)
        #expect(moved.end(at: CGPoint(x: g.x + 11, y: g.y), time: 0.6) == .tap)
    }

    @Test func tapJustUnderTheLongPressDelayIsATap() {
        var arb = GestureArbiter(start: .letter, origin: g, time: 0, keyHeight: 43)
        #expect(arb.tick(now: 0.349) == nil)
        #expect(arb.end(at: g, time: 0.349) == .tap)
    }

    @Test func flickUpAndDown() {
        let kh = r.keyHeight
        // Up and down by 0.5 key height: stays inside the neighbour boundary for the vertical hit test.
        let up = r.line(from: g, to: CGPoint(x: g.x + 2, y: g.y - kh * 0.6), duration: 0.12, steps: 6)
        #expect(r.run(up).final == .flickUp)
        let down = r.line(from: g, to: CGPoint(x: g.x - 2, y: g.y + kh * 0.6), duration: 0.12, steps: 6)
        #expect(r.run(down).final == .flickDown)
    }

    @Test func flickThatCrossesAKeyIsAFlickUnlessItFormsAWord() {
        let kh = r.keyHeight
        let a = r.centre(.letter("g")), b = CGPoint(x: a.x + 2, y: a.y - kh * 0.95) // lands on "t"/"y" row
        let s = r.line(from: a, to: b, duration: 0.15, steps: 8)
        #expect(r.run(s, likelyWord: false).final == .flickUp)
        #expect(r.run(s, likelyWord: true).final == .swipeTyping)
    }

    @Test func slowVerticalDragIsNotAFlick() {
        let kh = r.keyHeight
        let s = r.line(from: g, to: CGPoint(x: g.x, y: g.y - kh * 0.6), duration: 0.5, steps: 10)
        let out = r.run(s, ticks: false)
        #expect(out.final == .tap) // slow, within the key: a tap by the matrix
    }

    @Test func longVerticalTravelIsNotAFlick() {
        let kh = r.keyHeight
        // 1.6 key heights up within 150 ms crosses two rows: swipe typing (not a flick, beyond one key height).
        let s = r.line(from: g, to: CGPoint(x: g.x + 3, y: g.y - kh * 1.6), duration: 0.15, steps: 10)
        let out = r.run(s)
        #expect(out.final == .swipeTyping)
        #expect(out.early == [.swipeTyping])
    }

    @Test func diagonalDragIsNotAFlick() {
        let kh = r.keyHeight
        let s = r.line(from: g, to: CGPoint(x: g.x + kh * 0.7, y: g.y - kh * 0.7), duration: 0.12, steps: 6)
        #expect(r.run(s).final != .flickUp)
    }

    @Test func swipeTypingStartsAtTheFirstCrossing() {
        let s = r.line(from: g, to: r.centre(.letter("l")), duration: 0.4, steps: 20)
        let out = r.run(s)
        #expect(out.final == .swipeTyping)
        #expect(out.early == [.swipeTyping])
    }

    @Test func swipeThatEndsBackOnItsKeyStaysSwipeTyping() {
        let a = r.line(from: g, to: r.centre(.letter("k")), duration: 0.3, steps: 10)
        let b = r.line(from: r.centre(.letter("k")), to: g, duration: 0.3, steps: 10, t0: 0.3)
        #expect(r.run(a + b.dropFirst()).final == .swipeTyping)
    }

    // MARK: Spacebar

    @Test func spacebarDragMovesTheCursor() {
        let sp = r.centre(.space)
        let s = r.line(from: sp, to: CGPoint(x: sp.x + 40, y: sp.y), duration: 0.3)
        let out = r.run(s)
        #expect(out.final == .spacebarCursor)
        #expect(out.early == [.spacebarCursor])
    }

    @Test func spacebarVerticalDragAlsoMovesTheCursor() {
        let sp = r.centre(.space)
        #expect(r.run(r.line(from: sp, to: CGPoint(x: sp.x, y: sp.y - 20), duration: 0.3)).final == .spacebarCursor)
    }

    @Test func spacebarBelowTheDragStartIsATap() {
        let sp = r.centre(.space)
        #expect(r.run(r.line(from: sp, to: CGPoint(x: sp.x + 11.9, y: sp.y), duration: 0.2)).final == .tap)
        #expect(r.run(r.line(from: sp, to: CGPoint(x: sp.x + 12.5, y: sp.y), duration: 0.2)).final == .spacebarCursor)
    }

    @Test func spacebarWithShiftSelects() {
        let sp = r.centre(.space)
        let s = r.line(from: sp, to: CGPoint(x: sp.x - 50, y: sp.y), duration: 0.3)
        #expect(r.run(s, shift: true).final == .spacebarSelection)
        #expect(r.run(s, shift: false).final == .spacebarCursor)
    }

    @Test func spacebarNeverLongPresses() {
        let sp = r.centre(.space)
        var arb = GestureArbiter(start: .space, origin: sp, time: 0, keyHeight: 43)
        #expect(arb.tick(now: 5) == nil)
    }

    // MARK: Backspace

    @Test func backspaceLeftDragDeletesWordsOnRelease() {
        let d = r.centre(.delete)
        let s = r.line(from: d, to: CGPoint(x: d.x - 60, y: d.y), duration: 0.4)
        let out = r.run(s)
        #expect(out.early == [.backspaceSwipeDelete])
        // Released away from the keys: delete. (The replay's lift is over the keys, so use the arbiter directly.)
        var arb = GestureArbiter(start: .delete, origin: d, time: 0, keyHeight: 43)
        #expect(arb.move(to: CGPoint(x: d.x - 25, y: d.y), time: 0.2, crossedKeys: false) == .backspaceSwipeDelete)
        #expect(arb.end(at: CGPoint(x: d.x - 60, y: d.y), time: 0.4, endedOverKeys: false) == .backspaceSwipeDelete)
    }

    @Test func backspaceCancelledByDraggingBackOrOntoKeys() {
        let d = r.centre(.delete)
        var back = GestureArbiter(start: .delete, origin: d, time: 0, keyHeight: 43)
        _ = back.move(to: CGPoint(x: d.x - 40, y: d.y), time: 0.2, crossedKeys: false)
        #expect(back.end(at: CGPoint(x: d.x - 4, y: d.y), time: 0.5, endedOverKeys: false) == .backspaceSwipeCancel)
        var onto = GestureArbiter(start: .delete, origin: d, time: 0, keyHeight: 43)
        _ = onto.move(to: CGPoint(x: d.x - 40, y: d.y), time: 0.2, crossedKeys: false)
        #expect(onto.end(at: CGPoint(x: d.x - 40, y: d.y), time: 0.5, endedOverKeys: true) == .backspaceSwipeCancel)
    }

    @Test func backspaceShortDragAndRightDragAreTaps() {
        let d = r.centre(.delete)
        #expect(r.run(r.line(from: d, to: CGPoint(x: d.x - 19, y: d.y), duration: 0.2)).final == .tap)
        #expect(r.run(r.line(from: d, to: CGPoint(x: d.x + 5, y: d.y), duration: 0.2)).final == .tap)
    }

    @Test func otherKeysOnlyTap() {
        let shift = r.centre(.shift)
        #expect(r.run(r.line(from: shift, to: CGPoint(x: shift.x + 80, y: shift.y), duration: 0.3)).final == .tap)
    }

    @Test func thresholdsAreTunable() {
        var t = GestureThresholds()
        t.spacebarDragStart = 30
        let sp = r.centre(.space)
        #expect(r.run(r.line(from: sp, to: CGPoint(x: sp.x + 20, y: sp.y), duration: 0.2), thresholds: t).final == .tap)
        t.longPressDelay = 0.2
        var arb = GestureArbiter(start: .letter, origin: g, time: 0, keyHeight: 43, thresholds: t)
        #expect(arb.tick(now: 0.2) == .longPress)
    }
}

// MARK: - Swipe words must never look like another gesture

@Suite("Gesture arbiter on synthetic swipe words")
struct GestureArbiterSwipeWordTests {
    fileprivate let r = Replay()

    private func words() throws -> [String] {
        let lex = try Lexicon(url: fixtureURL("lexicon.iblex"))
        return (0..<lex.wordCount).map { lex.word(of: UInt32($0)) }
            .filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
    }

    /// 500 synthetic traces of real fixture words at three jitter levels and varied speed (SYNTHETIC: no recorded
    /// traces exist yet).
    private func traces() throws -> [[Sample]] {
        let ws = try words()
        var rng = TraceRNG(seed: 2027)
        var out: [[Sample]] = []
        var i = 0
        while out.count < 500 {
            let w = ws[i % ws.count]
            i += 1
            let jitter = [0.12, 0.22, 0.32][i % 3]
            guard let pts = TraceFixtures.swipe(w, layout: r.layout, jitter: jitter, keysPerSecond: rng.range(3, 12), rng: &rng) else { continue }
            let first = CGPoint(x: pts[0].x, y: pts[0].y)
            guard r.startKind(at: first) == .letter else { continue } // jitter pushed the start off the letters
            out.append(pts.map { Sample(x: $0.x, y: $0.y, t: $0.t) })
        }
        return out
    }

    @Test func fiveHundredSwipeWordsAreNeverFlicksSelectionsCursorsOrDeletes() throws {
        let ts = try traces()
        #expect(ts.count == 500)
        var counts: [String: Int] = [:]
        for s in ts {
            for lw in [true, false] {
                let out = r.run(s, shift: false, likelyWord: lw)
                for g in out.early + [out.final] { counts["\(g)", default: 0] += 1 }
                if lw { #expect(out.final == .swipeTyping, "likely word was not swipe typing: \(out.final)") }
                #expect(![.spacebarCursor, .spacebarSelection, .backspaceSwipeDelete, .backspaceSwipeCancel, .longPress, .tap].contains(out.final))
            }
            // Shift armed changes nothing for a letter-key start: no selection.
            #expect(r.run(s, shift: true, likelyWord: true).final == .swipeTyping)
        }
        // Even when the decoder does not consider the keys a likely word, no flick (the words are real, 3+ letters).
        #expect(counts["flickUp", default: 0] + counts["flickDown", default: 0] == 0, "\(counts)")
    }

    @Test func swipeThatStartsOnSpaceOrDeleteIsNeverSwipeTyping() throws {
        let ts = try traces()
        for s in ts.prefix(100) {
            // The same path shifted down onto the space bar row start.
            let sp = r.centre(.space)
            let moved = s.map { Sample(x: $0.x - s[0].x + Double(sp.x), y: $0.y - s[0].y + Double(sp.y), t: $0.t) }
            #expect(r.run(moved).final != .swipeTyping)
        }
    }
}
