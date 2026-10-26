import CoreGraphics
import Foundation
import Testing
import IBoardEngine
import IBoardLayout

/// M4-04 synthetic swipe eval. Every number printed here is SYNTHETIC (generated traces over fixture lexicons,
/// macOS host, generator and decoder by the same author) and says nothing about real fingers.
@Suite struct SwipeEvalTests {
    private func run(label: String, lex: Lexicon, lm: NGramModel, ids: Int, perProfile: Int,
                     layout: KeyboardLayout = testLayout) -> [String: SwipeScore] {
        let dec = SwipeDecoder(layout: layout, lexicon: lex, model: lm)
        var byProfile: [String: SwipeScore] = [:]
        var overall = SwipeScore()
        for (pi, profile) in SwipeProfile.all.enumerated() {
            var rng = SplitMix64(seed: 1000 + UInt64(pi))
            var s = SwipeScore()
            for w in swipeSampleWords(lex, upTo: ids, count: perProfile, seed: 77 + UInt64(pi)) {
                guard let pts = SwipeSynth.trace(w, layout: layout, profile: profile, rng: &rng) else { continue }
                let r = dec.decode(points: pts)
                s.add(truth: w, result: r)
                overall.add(truth: w, result: r)
            }
            print(s.line("\(label) / \(profile.name)"))
            byProfile[profile.name] = s
        }
        print(overall.line("\(label) / all profiles"))
        byProfile["all"] = overall
        return byProfile
    }

    @Test func syntheticAccuracySmallLexicon() throws {
        let lex = try Fixture.small.lexicon()
        let lm = try Fixture.small.model(lexicon: lex)
        let r = run(label: "small fixture (\(lex.wordCount) words)", lex: lex, lm: lm, ids: lex.wordCount, perProfile: 600)
        let all = try #require(r["all"])
        print("SYNTHETIC F3 targets: top-1 90%, top-3 97% -> top-1 \(all.top1Rate >= 0.9 ? "MEETS" : "MISSES"), "
              + "top-3 \(all.top3Rate >= 0.97 ? "MEETS" : "MISSES") on the small synthetic lexicon. "
              + "Not evidence of real-world accuracy.")
        // Loose regression floors only.
        #expect(all.top1Rate >= 0.75)
        #expect(all.top3Rate >= 0.88)
        let careful = try #require(r["careful"]), sloppy = try #require(r["sloppy"])
        #expect(careful.top1Rate >= sloppy.top1Rate - 0.02)
    }

    @Test func syntheticAccuracyBenchLexicon() throws {
        // 12k words: 219 real ones plus random-syllable pseudo-words (many look-alike distractors). Targets are the
        // real words only (the first ids), the pseudo-words only compete.
        let lex = try Fixture.bench.lexicon()
        let lm = try Fixture.bench.model(lexicon: lex)
        let r = run(label: "bench fixture (\(lex.wordCount) words, targets = top 200 ids)", lex: lex, lm: lm,
                    ids: 200, perProfile: 400)
        let all = try #require(r["all"])
        #expect(all.top1Rate >= 0.6)
        #expect(all.top3Rate >= 0.8)
    }

    @Test func syntheticAccuracyDuoLayout() throws {
        let lex = try Fixture.small.lexicon()
        let lm = try Fixture.small.model(lexicon: lex)
        let layout = LayoutEngine.layout(containerSize: CGSize(width: 900, height: 300),
                                         traits: LayoutTraits(displayClass: .duoInner, orientation: .landscape), kind: .letters)
        let r = run(label: "small fixture on duoInner landscape layout", lex: lex, lm: lm, ids: lex.wordCount,
                    perProfile: 300, layout: layout)
        #expect(try #require(r["all"]).top1Rate >= 0.7)
    }
}
