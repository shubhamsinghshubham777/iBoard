import Foundation
import Testing
import IBoardCore
import IBoardEngine

/// macOS host benchmarks of the runtime readers on the 12k-word `bench` fixture (or `IBOARD_BENCH_DIR`).
/// ROADMAP section 6 gives "keystroke -> suggestions" p95 <= 25 ms for the whole pipeline (iPhone 12). Each reader
/// operation below must fit in a small fraction of that, asserted as: a batch of the operations a keystroke needs
/// (below) stays within the full budget with NO slack. Debug builds are slower than the shipping -O build.
@Suite struct ReaderBenchmarks {
    private func fixture() throws -> (Lexicon, NGramModel, [String]) {
        if let (l, m) = externalBenchFixture() {
            return (l, m, (0..<min(l.wordCount, 4000)).map { l.word(of: UInt32($0 * (l.wordCount / min(l.wordCount, 4000)))) })
        }
        let lex = try Fixture.bench.lexicon()
        let lm = try Fixture.bench.model(lexicon: lex)
        return (lex, lm, (0..<2000).map { lex.word(of: UInt32($0 * 6)) })
    }

    @Test func exactLookup() throws {
        let (lex, _, words) = try fixture()
        nonisolated(unsafe) var sink: UInt32 = 0
        // 1,000 lookups per iteration, far more than a keystroke needs.
        let p95 = Benchmark.measure("lexicon exact lookup x1000", opsPerIteration: 1000) {
            for i in 0..<1000 { sink &+= lex.lookup(words[i]) ?? 0 }
        }
        #expect(sink > 0)
        Benchmark.assertBudget(p95, PerfMetric.keystrokeToSuggestions.budgetMilliseconds)
    }

    @Test func prefixCompletions() throws {
        let (lex, _, words) = try fixture()
        let prefixes = words.prefix(200).map { String($0.prefix(2)) }
        nonisolated(unsafe) var sink = 0
        nonisolated(unsafe) var sc = CompletionScratch()
        nonisolated(unsafe) var o: [UInt32] = []
        o.reserveCapacity(16)
        let p95 = Benchmark.measure("lexicon top-8 completions of 2-letter prefix x200", opsPerIteration: 200) {
            for p in prefixes {
                guard let c = lex.cursor(for: p) else { continue }
                lex.completions(of: c, limit: 8, scratch: &sc, into: &o)
                sink &+= o.count
            }
        }
        #expect(sink > 0)
        Benchmark.assertBudget(p95, PerfMetric.keystrokeToSuggestions.budgetMilliseconds)
    }

    @Test func languageModelScoring() throws {
        let (lex, lm, words) = try fixture()
        let ids = words.prefix(300).compactMap { lex.lookup($0) }
        nonisolated(unsafe) var sink = 0.0
        let p95 = Benchmark.measure("LM trigram P(w|a,b) x1000", opsPerIteration: 1000) {
            for i in 0..<1000 {
                let ctx = LMContext(older: ids[i % ids.count], recent: ids[(i * 7 + 1) % ids.count])
                sink += lm.probability(ids[(i * 13 + 5) % ids.count], context: ctx)
            }
        }
        #expect(sink > 0)
        Benchmark.assertBudget(p95, PerfMetric.keystrokeToSuggestions.budgetMilliseconds)
    }

    @Test func openingIsCheap() throws {
        // mmap open without checksum scan; reports the open time (not a roadmap budget).
        let url = Fixture.bench.url("lexicon", "iblex")
        Benchmark.measure("open lexicon (mmap, no checksum)", iterations: 100) { _ = try? Lexicon(url: url, verifyChecksum: false) }
        Benchmark.measure("open lexicon (mmap, FNV checksum scan)", iterations: 20) { _ = try? Lexicon(url: url, verifyChecksum: true) }
    }
}
