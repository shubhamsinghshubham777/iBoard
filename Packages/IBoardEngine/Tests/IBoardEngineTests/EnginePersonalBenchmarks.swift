import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

@Suite struct EnginePersonalBenchmarks {
    /// Engine time of one keystroke / prediction with a full-size personal model (10k unigrams, ~10k bigrams).
    /// Measured on the macOS host (not a device). Run with `swift test -c release`.
    @Test func keystrokeWithLargePersonalModel() async throws {
        let lex = try Fixture.bench.lexicon()
        let lm = try Fixture.bench.model(lexicon: lex)
        let e = EngineActor(layout: testLayout, lexicon: lex, model: lm)
        let st = PersonalStore(storage: InMemoryPersonalStorage(), clock: ManualPersonalClock())
        var prev = "start"
        for i in 0..<10_000 {
            let w = "pw\(i)x"
            await st.learn(word: w, context: [prev], increment: 1)
            prev = w
        }
        await e.refreshPersonal(from: st)
        var rng = SplitMix64(seed: 3)
        let words = (0..<60).map { lex.word(of: UInt32($0)) }.filter { $0.allSatisfy { $0.isASCII && $0.isLetter } }
        var cases: [[CGPoint]] = []
        for w in words {
            let t = trace(w, noise: 0.3, rng: &rng)
            for n in 1...t.count { cases.append(Array(t.prefix(n))) }
        }
        var times: [Double] = []
        for i in 0..<400 {
            let seq = e.beginRequest()
            let t0 = ContinuousClock.now
            _ = await e.submit(EngineRequest(sequence: seq,
                                             touches: .points(i % 8 == 7 ? [] : cases[i % cases.count]),
                                             previousWords: ["pw5x"]))
            let d = ContinuousClock.now - t0
            times.append(Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15)
        }
        times.sort()
        print("BENCH engine+personal(10k uni/10k bi) per request: p50 \(times[200]) ms, p95 \(times[380]) ms")
        #if !DEBUG
        #expect(times[380] <= 25)
        #endif
    }
}
