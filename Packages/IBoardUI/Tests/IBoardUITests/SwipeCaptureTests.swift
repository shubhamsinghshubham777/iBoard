import CoreGraphics
import Foundation
import Testing
import IBoardEngine
import IBoardLayout
@testable import IBoardUI

@Suite struct SwipeCaptureTests {
    let layout = TraceFixtures.layout

    private func run(_ cap: inout SwipeCapture, _ pts: [SwipePoint], id: Int = 1) -> (updates: [SwipeCaptureUpdate], out: [SwipePoint]?) {
        var ups: [SwipeCaptureUpdate] = []
        _ = cap.begin(id: id, at: CGPoint(x: pts[0].x, y: pts[0].y), time: pts[0].t, layout: layout)
        for p in pts.dropFirst().dropLast() {
            ups.append(cap.move(id: id, to: CGPoint(x: p.x, y: p.y), time: p.t, layout: layout))
        }
        let l = pts.last!
        return (ups, cap.end(id: id, at: CGPoint(x: l.x, y: l.y), time: l.t))
    }

    @Test func tapOnOneKeyIsNeverASwipe() {
        var cap = SwipeCapture()
        let c = TraceFixtures.centre("g")
        let began = cap.begin(id: 1, at: c, time: 0, layout: layout)
        #expect(began)
        for i in 0..<10 {
            let u = cap.move(id: 1, to: CGPoint(x: c.x + CGFloat(i % 3), y: c.y - CGFloat(i % 2)), time: Double(i) * 0.01, layout: layout)
            #expect(u == SwipeCaptureUpdate.none)
        }
        let out = cap.end(id: 1, at: c, time: 0.2)
        #expect(out == nil)
        #expect(cap.phase == .idle)
    }

    @Test func crossingAnotherLetterKeyBecomesASwipe() {
        var cap = SwipeCapture()
        var rng = TraceRNG(seed: 1)
        let pts = TraceFixtures.swipe("hello", rng: &rng)!
        let r = run(&cap, pts)
        #expect(r.updates.filter { $0 == .began }.count == 1)
        #expect(r.updates.first { $0 != SwipeCaptureUpdate.none } == .began)
        #expect(r.out != nil)
        #expect(r.out!.first!.x == pts.first!.x)
        #expect(r.out!.last!.x == pts.last!.x)
    }

    @Test func startingOnNonLetterKeysIsNotTracked() {
        var cap = SwipeCapture()
        let space = layout.firstKey(.space)!.frame
        let a = cap.begin(id: 1, at: CGPoint(x: space.midX, y: space.midY), time: 0, layout: layout)
        #expect(!a)
        #expect(cap.phase == .idle)
        let numbers = LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .numbers)
        let f = numbers.keys.first { if case .symbol = $0.identity { true } else { false } }!.frame
        let b = cap.begin(id: 1, at: CGPoint(x: f.midX, y: f.midY), time: 0, layout: numbers)
        #expect(!b)
    }

    @Test func movingOntoANonLetterKeyDoesNotStartASwipe() {
        var cap = SwipeCapture()
        let z = TraceFixtures.centre("z")
        _ = cap.begin(id: 1, at: z, time: 0, layout: layout)
        let shift = layout.keys.first { $0.identity == .shift }!.frame
        let u = cap.move(id: 1, to: CGPoint(x: shift.midX, y: shift.midY), time: 0.1, layout: layout)
        #expect(u == SwipeCaptureUpdate.none)
        #expect(cap.phase == .undecided)
    }

    @Test func secondFingerIsIgnoredWhileOneIsTracked() {
        var cap = SwipeCapture()
        let b1 = cap.begin(id: 1, at: TraceFixtures.centre("a"), time: 0, layout: layout)
        let b2 = cap.begin(id: 2, at: TraceFixtures.centre("k"), time: 0, layout: layout)
        let u = cap.move(id: 2, to: TraceFixtures.centre("l"), time: 0.1, layout: layout)
        #expect(b1 && !b2 && u == SwipeCaptureUpdate.none)
        #expect(cap.tracks(1) && !cap.tracks(2))
    }

    @Test func memoryIsBoundedAndCancelResets() {
        var cap = SwipeCapture()
        var rng = TraceRNG(seed: 5)
        _ = cap.begin(id: 1, at: TraceFixtures.centre("a"), time: 0, layout: layout)
        for i in 1..<5000 {
            let x = 40 + 300 * (0.5 + 0.5 * sin(Double(i) / 7)), y = 120 + 80 * rng.unit()
            _ = cap.move(id: 1, to: CGPoint(x: x, y: y), time: Double(i) / 120, layout: layout)
        }
        #expect(cap.points.count <= cap.parameters.maxRawPoints + 1)
        #expect(cap.trail.count <= cap.parameters.maxTrailPoints + 1)
        let out = cap.end(id: 1, at: CGPoint(x: 200, y: 150), time: 50)
        #expect(out != nil && out!.count <= cap.parameters.maxRawPoints + 2)
        #expect(out?.last?.t == 50) // the lift point survives decimation
        _ = cap.begin(id: 1, at: TraceFixtures.centre("a"), time: 0, layout: layout)
        cap.cancel()
        #expect(cap.phase == .idle && cap.points.isEmpty && cap.trail.isEmpty)
    }

    @Test func trailIsEquidistantWithLiveHead() {
        var cap = SwipeCapture()
        _ = cap.begin(id: 1, at: CGPoint(x: 100, y: 150), time: 0, layout: layout)
        _ = cap.move(id: 1, to: CGPoint(x: 160, y: 150), time: 0.1, layout: layout)
        _ = cap.move(id: 1, to: CGPoint(x: 202, y: 150), time: 0.2, layout: layout)
        let t = cap.trail
        for i in 1..<(t.count - 1) { #expect(abs(hypot(t[i].x - t[i - 1].x, t[i].y - t[i - 1].y) - cap.parameters.trailSpacing) < 0.01) }
        #expect(t.last == CGPoint(x: 202, y: 150))
    }

    @Test func subPixelJitterIsDropped() {
        var cap = SwipeCapture()
        let a = TraceFixtures.centre("q")
        _ = cap.begin(id: 1, at: a, time: 0, layout: layout)
        for i in 1...20 { _ = cap.move(id: 1, to: CGPoint(x: a.x + CGFloat(i) * 0.05, y: a.y), time: Double(i) * 0.01, layout: layout) }
        #expect(cap.points.count <= 2)
    }

    @Test func outputIsOrderedAndNotLongerThanInput() throws {
        var cap = SwipeCapture()
        var rng = TraceRNG(seed: 9)
        let pts = TraceFixtures.swipe("quick", rng: &rng)!
        let r = run(&cap, pts)
        let out = try #require(r.out)
        #expect(out.count > 8 && out.count <= pts.count)
        #expect(out.map(\.t) == out.map(\.t).sorted())
    }
}
