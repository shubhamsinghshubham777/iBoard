import CoreGraphics
import Foundation
import Testing
import IBoardCore
import IBoardEngine
import IBoardLayout

/// Frequency-weighted words (Zipf-like through the unigram log-probabilities), >= 3 letters, from the first
/// `ids` lexicon ids. Deterministic for a seed.
func swipeSampleWords(_ lex: Lexicon, upTo ids: Int, count: Int, seed: UInt64) -> [String] {
    var words: [String] = []
    var weights: [Double] = []
    for id in 0..<min(ids, lex.wordCount) {
        let w = lex.word(of: UInt32(id))
        guard w.count >= 3, w.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
        words.append(w)
        weights.append(exp(lex.logProbability(of: UInt32(id))))
    }
    let total = weights.reduce(0, +)
    var rng = SplitMix64(seed: seed)
    var out: [String] = []
    for _ in 0..<count {
        var r = Double(rng.next() >> 11) / Double(1 << 53) * total
        var pick = words.count - 1
        for (i, w) in weights.enumerated() { r -= w; if r <= 0 { pick = i; break } }
        out.append(words[pick])
    }
    return out
}

/// M4-02 latency benchmarks (ROADMAP section 6: swipe lift to top candidate p95 <= 60 ms on iPhone 12). Measured on
/// the macOS host over fixture lexicons: a host number, not a device number, and not a realistic 100k-word lexicon
/// unless `IBOARD_BENCH_DIR` points at one.
@Suite struct SwipeBenchmarks {
    @Test func liftToTopCandidateLatency() throws {
        var lex: Lexicon, lm: NGramModel, label: String, ids: Int
        if let (l, m) = externalBenchFixture() {
            lex = l; lm = m; label = "external \(l.wordCount) words"; ids = 2000
        } else {
            lex = try Fixture.bench.lexicon()
            lm = try Fixture.bench.model(lexicon: lex)
            label = "bench fixture \(lex.wordCount) words"; ids = 200
        }
        let dec = SwipeDecoder(layout: testLayout, lexicon: lex, model: lm)
        var rng = SplitMix64(seed: 5)
        var traces: [[SwipePoint]] = []
        for w in swipeSampleWords(lex, upTo: ids, count: 300, seed: 21) {
            if let t = SwipeSynth.trace(w, layout: testLayout, profile: .normal, rng: &rng) { traces.append(t) }
        }
        nonisolated(unsafe) var i = 0
        nonisolated(unsafe) var sink = 0
        let p95 = Benchmark.measure("swipe decode lift->top candidate (\(label), \(traces.count) traces)",
                                    warmup: 50, iterations: 1500) {
            sink &+= dec.decode(points: traces[i % traces.count]).candidates.count
            i += 1
        }
        #expect(sink > 0)
        #expect(p95 <= PerfMetric.swipeLiftToCandidate.budgetMilliseconds)
        var visited = 0, scored = 0, cut = 0
        for t in traces {
            let r = dec.decode(points: t)
            visited += r.nodesVisited; scored += r.scoredCount; cut += r.truncated ? 1 : 0
        }
        print("BENCH swipe work per decode (\(label)): mean trie nodes visited \(visited / traces.count), "
              + "mean templates scored \(scored / traces.count), truncated \(cut)")
    }

    /// Worst case: long wandering paths over the whole keyboard (huge corridor), the lexicon walk is as wide as it gets.
    @Test func adversarialWanderingPathLatency() throws {
        var lex: Lexicon, lm: NGramModel, label: String
        if let (l, m) = externalBenchFixture() {
            lex = l; lm = m; label = "external \(l.wordCount) words"
        } else {
            lex = try Fixture.bench.lexicon()
            lm = try Fixture.bench.model(lexicon: lex)
            label = "bench fixture \(lex.wordCount) words"
        }
        let dec = SwipeDecoder(layout: testLayout, lexicon: lex, model: lm)
        let letters = Array("qwertyuiopasdfghjklzxcvbnm")
        var rng = SplitMix64(seed: 99)
        var traces: [[SwipePoint]] = []
        for _ in 0..<100 {
            var word = ""
            for _ in 0..<(10 + Int(rng.next() % 6)) { word.append(letters[Int(rng.next() % 26)]) }
            if let t = SwipeSynth.trace(word, layout: testLayout, profile: .sloppy, rng: &rng) { traces.append(t) }
        }
        nonisolated(unsafe) var i = 0
        nonisolated(unsafe) var sink = 0
        let p95 = Benchmark.measure("swipe decode ADVERSARIAL random 10-15 key wander (\(label), \(traces.count) traces)",
                                    warmup: 20, iterations: 400) {
            sink &+= dec.decode(points: traces[i % traces.count]).nodesVisited
            i += 1
        }
        #expect(sink > 0)
        #expect(p95 <= PerfMetric.swipeLiftToCandidate.budgetMilliseconds)
    }
}
