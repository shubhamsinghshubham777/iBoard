import CoreGraphics
import Foundation
import Testing
import IBoardEngine
import IBoardLayout
@testable import IBoardUI

private func fixtureURL(_ file: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("IBoardEngine/Tests/IBoardEngineTests/Fixtures/small/\(file)")
}

@Suite("SwipeEngine on the small fixture")
struct SwipeEngineTests {
    let layout = TraceFixtures.layout
    let lex: Lexicon
    let engine: SwipeEngine

    init() throws {
        lex = try Lexicon(url: fixtureURL("lexicon.iblex"))
        let lm = try NGramModel(url: fixtureURL("lm.iblm"), lexicon: lex)
        engine = SwipeEngine(layout: layout, lexicon: lex, model: lm)
    }

    private var words: [String] {
        (0..<lex.wordCount).map { lex.word(of: UInt32($0)) }.filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
    }

    @Test func syntheticTracesDecodeThroughTheEngine() async {
        var top1 = 0, top3 = 0, n = 0
        var rng = TraceRNG(seed: 11)
        for w in words {
            guard let pts = TraceFixtures.swipe(w, rng: &rng) else { continue }
            n += 1
            let out = await engine.decode(points: pts, previousWords: [])
            if out?.words.first == w { top1 += 1 }
            if out?.words.contains(w) == true { top3 += 1 }
        }
        #expect(n > 100)
        #expect(Double(top3) / Double(n) > 0.9, "top1 \(top1) top3 \(top3) of \(n)")
    }

    /// What a coarse injected gesture looks like: only a handful of samples, seconds apart.
    @Test func sparseStraightSwipeAlongTheHomeRowDecodesAll() async {
        let t = TraceFixtures.centre("a"), p = TraceFixtures.centre("l")
        let pts = (0...4).map { i -> SwipePoint in
            let f = Double(i) / 4
            return SwipePoint(x: Double(t.x) + Double(p.x - t.x) * f, y: Double(t.y), t: 100 + Double(i) * 0.4)
        }
        let out = await engine.decode(points: pts, previousWords: [])
        #expect(out != nil)
        #expect(out?.words.first == "all", "\(String(describing: out))")
    }

    @Test func tapLikePathIsNil() async {
        let c = TraceFixtures.centre("h")
        let out = await engine.decode(points: [SwipePoint(c, t: 0), SwipePoint(c, t: 0.1)], previousWords: [])
        #expect(out == nil)
    }
}
