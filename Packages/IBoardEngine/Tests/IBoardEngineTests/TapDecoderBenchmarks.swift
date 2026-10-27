import CoreGraphics
import Foundation
import Testing
import IBoardCore
import IBoardEngine
import IBoardLayout

/// Keystroke -> suggestions (ROADMAP section 6: p95 <= 25 ms on iPhone 12). Measures the engine part only
/// (decode after each keystroke, with LM context), on the macOS host. Not a device number.
@Suite struct TapDecoderBenchmarks {
    private func setup() throws -> (TapDecoder, [[CGPoint]], String) {
        var lex: Lexicon, lm: NGramModel, label: String
        if let (l, m) = externalBenchFixture() {
            lex = l; lm = m; label = "external \(l.wordCount) words"
        } else {
            lex = try Fixture.bench.lexicon()
            lm = try Fixture.bench.model(lexicon: lex)
            label = "bench fixture \(lex.wordCount) words"
        }
        let dec = TapDecoder(layout: testLayout, lexicon: lex, model: lm)
        // Real words come first in rank order in both fixtures (ids 0..<~100): typical typing.
        var rng = SplitMix64(seed: 5)
        var cases: [[CGPoint]] = []
        for id in 0..<UInt32(120) {
            let w = lex.word(of: id)
            guard w.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            let pts = trace(w, noise: 0.3, rng: &rng)
            for n in 1...pts.count { cases.append(Array(pts.prefix(n))) }   // every keystroke of the word
        }
        return (dec, cases, label)
    }

    @Test func keystrokeToSuggestionsEngineTime() throws {
        let (dec, cases, label) = try setup()
        let ctxs = [LMContext.none, LMContext(recent: 0), LMContext(older: 1, recent: 0)]
        nonisolated(unsafe) var i = 0
        nonisolated(unsafe) var sink = 0
        let p95 = Benchmark.measure("tap decode per keystroke (\(label), \(cases.count) distinct prefixes)",
                                    warmup: 200, iterations: 3000) {
            let r = dec.decode(points: cases[i % cases.count], context: ctxs[i % 3])
            sink &+= r.candidates.count
            i += 1
        }
        #expect(sink > 0)
        Benchmark.assertBudget(p95, PerfMetric.keystrokeToSuggestions.budgetMilliseconds)
    }

    @Test func accuracyOnBenchLexicon() throws {
        // Real words among 12k pseudo-words: many more near neighbours than the 219-word fixture.
        let lex = try Fixture.bench.lexicon()
        let lm = try Fixture.bench.model(lexicon: lex)
        let dec = TapDecoder(layout: testLayout, lexicon: lex, model: lm)
        var rng = SplitMix64(seed: 11)
        var lit = 0, top = 0, total = 0
        for id in 0..<UInt32(200) {
            let w = lex.word(of: id)
            guard w.count >= 4, w.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            for _ in 0..<5 {
                let r = dec.decode(points: trace(w, noise: 0.3, rng: &rng))
                total += 1
                if r.literal == w { lit += 1 }
                if r.candidates.first?.word == w { top += 1 }
            }
        }
        print("TAPACC bench-12k noise 0.3: literal \(Double(lit) / Double(total)), decoder top-1 \(Double(top) / Double(total)), n=\(total)")
        #expect(top >= lit)
    }
}
