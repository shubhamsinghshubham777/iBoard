import CoreGraphics
import Foundation
import Testing
import IBoardCore
import IBoardEngine
import IBoardLayout

/// M7-02 latency with both lexicons searched (ROADMAP section 6: keystroke -> suggestions p95 <= 25 ms, swipe lift ->
/// top candidate p95 <= 60 ms on iPhone 12). macOS host numbers, run with `swift test -c release`; not device
/// numbers. Primary = `IBOARD_BENCH_DIR` (a larger English-sized lexicon) or the 12k bench fixture; secondary = the real
/// Hinglish artifacts in Data/hinglish (skipped when absent).
@Suite struct DualBenchmarks {
    private func languages() throws -> (en: Lexicon, enLM: NGramModel, hi: Lexicon, hiLM: NGramModel, label: String)? {
        guard let (hi, hiLM) = realHinglish() else { return nil }
        if let (l, m) = externalBenchFixture() {
            return (l, m, hi, hiLM, "EN external \(l.wordCount) words + Hinglish \(hi.wordCount)")
        }
        let l = try Fixture.bench.lexicon()
        return (l, try Fixture.bench.model(lexicon: l), hi, hiLM, "EN bench fixture \(l.wordCount) words + Hinglish \(hi.wordCount)")
    }

    private func asciiWord(_ lex: Lexicon, _ id: Int) -> String? {
        let w = lex.word(of: UInt32(id))
        return w.allSatisfy { $0.isASCII && $0.isLetter } ? w : nil
    }

    @Test func tapKeystrokeBothLexicons() throws {
        guard let L = try languages() else { return }
        let sec = SecondaryLanguage(lexicon: L.hi, model: L.hiLM)
        let dual = TapDecoder(layout: testLayout, lexicon: L.en, model: L.enLM, secondary: sec)
        let single = TapDecoder(layout: testLayout, lexicon: L.en, model: L.enLM)
        var rng = SplitMix64(seed: 5)
        var cases: [([CGPoint], [String])] = []
        let histories: [[String]] = [[], ["kya", "hai"], ["the", "good"], ["mera", "phone"]]
        var n = 0
        for id in 0..<400 where n < 80 {
            // Alternate Hinglish and English words, typed with 0.3 key-size noise, every keystroke.
            for lex in [L.hi, L.en] {
                guard let w = asciiWord(lex, id) else { continue }
                let pts = trace(w, noise: 0.3, rng: &rng)
                for k in 1...pts.count { cases.append((Array(pts.prefix(k)), histories[(n + k) % histories.count])) }
                n += 1
            }
        }
        let ctxs = cases.map { CodeSwitch.context(previousWords: $0.1, primary: L.en, secondary: sec, parameters: CodeSwitchParameters()) }
        nonisolated(unsafe) var i = 0
        nonisolated(unsafe) var sink = 0
        let dualP95 = Benchmark.measure("DUAL tap decode per keystroke (\(L.label), \(cases.count) prefixes)", warmup: 200, iterations: 3000) {
            let j = i % cases.count
            sink &+= dual.decode(points: cases[j].0, context: ctxs[j].primary, secondaryContext: ctxs[j].secondary).candidates.count
            i += 1
        }
        i = 0
        let singleP95 = Benchmark.measure("single tap decode per keystroke (\(L.label), English only)", warmup: 200, iterations: 3000) {
            let j = i % cases.count
            sink &+= single.decode(points: cases[j].0, context: ctxs[j].primary).candidates.count
            i += 1
        }
        print("BENCH tap p95 dual \(String(format: "%.3f", dualP95)) ms vs single \(String(format: "%.3f", singleP95)) ms")
        #expect(sink > 0)
        Benchmark.assertBudget(dualP95, PerfMetric.keystrokeToSuggestions.budgetMilliseconds)
    }

    @Test func swipeLiftBothLexicons() throws {
        guard let L = try languages() else { return }
        let sec = SecondaryLanguage(lexicon: L.hi, model: L.hiLM)
        let dual = SwipeDecoder(layout: testLayout, lexicon: L.en, model: L.enLM, secondary: sec)
        let single = SwipeDecoder(layout: testLayout, lexicon: L.en, model: L.enLM)
        var rng = SplitMix64(seed: 5)
        var traces: [[SwipePoint]] = []
        for lex in [L.hi, L.en] {
            for w in swipeSampleWords(lex, upTo: 2000, count: 150, seed: 21) {
                if let t = SwipeSynth.trace(w, layout: testLayout, profile: .normal, rng: &rng) { traces.append(t) }
            }
        }
        nonisolated(unsafe) var i = 0
        nonisolated(unsafe) var sink = 0
        let dualP95 = Benchmark.measure("DUAL swipe decode lift->top (\(L.label), \(traces.count) traces)", warmup: 50, iterations: 1500) {
            sink &+= dual.decode(points: traces[i % traces.count]).candidates.count
            i += 1
        }
        i = 0
        let singleP95 = Benchmark.measure("single swipe decode lift->top (\(L.label), English only)", warmup: 50, iterations: 1500) {
            sink &+= single.decode(points: traces[i % traces.count]).candidates.count
            i += 1
        }
        var visited = 0, cut = 0
        for t in traces { let r = dual.decode(points: t); visited += r.nodesVisited; cut += r.truncated ? 1 : 0 }
        print("BENCH swipe p95 dual \(String(format: "%.3f", dualP95)) ms vs single \(String(format: "%.3f", singleP95)) ms; "
              + "mean nodes visited (dual) \(visited / traces.count), truncated \(cut)")
        #expect(sink > 0)
        Benchmark.assertBudget(dualP95, PerfMetric.swipeLiftToCandidate.budgetMilliseconds)
    }

    /// Worst case: long random wandering paths (wide corridor), both tries walked.
    @Test func swipeAdversarialWanderBothLexicons() throws {
        guard let L = try languages() else { return }
        let dual = SwipeDecoder(layout: testLayout, lexicon: L.en, model: L.enLM,
                                secondary: SecondaryLanguage(lexicon: L.hi, model: L.hiLM))
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
        let p95 = Benchmark.measure("DUAL swipe ADVERSARIAL random 10-15 key wander (\(L.label), \(traces.count) traces)",
                                    warmup: 20, iterations: 400) {
            sink &+= dual.decode(points: traces[i % traces.count]).nodesVisited
            i += 1
        }
        #expect(sink > 0)
        Benchmark.assertBudget(p95, PerfMetric.swipeLiftToCandidate.budgetMilliseconds)
    }
}
