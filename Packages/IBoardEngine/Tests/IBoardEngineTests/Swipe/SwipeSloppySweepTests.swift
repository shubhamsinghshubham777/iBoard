import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

/// SWIPE3: per-profile F3 report on the real English and Hinglish data (SYNTHETIC traces) plus an opt-in parameter
/// sweep (IBOARD_SWEEP=1). The report test only prints; floors are asserted in SwipeEvalTests.
@Suite struct SwipeSloppySweepTests {
    struct Report { var en: [String: SwipeScore]; var hi: [String: SwipeScore] }

    static func evaluate(_ p: SwipeParameters, en: Lexicon, enLM: NGramModel, hi: Lexicon, hiLM: NGramModel) -> Report {
        // English only: 5000 most frequent, 400 per profile.
        let decEn = SwipeDecoder(layout: testLayout, lexicon: en, model: enLM, parameters: p)
        var enR: [String: SwipeScore] = [:]
        for (pi, profile) in SwipeProfile.all.enumerated() {
            var rng = SplitMix64(seed: 3100 + UInt64(pi))
            var s = SwipeScore()
            for w in swipeSampleWords(en, upTo: 5000, count: 400, seed: 31 + UInt64(pi)) {
                guard let pts = SwipeSynth.trace(w, layout: testLayout, profile: profile, rng: &rng) else { continue }
                s.add(truth: w, result: decEn.decode(points: pts))
            }
            enR[profile.name] = s
        }
        // Hinglish mixed sentences (both halves), English primary + Hinglish secondary.
        let sec = SecondaryLanguage(lexicon: hi, model: hiLM)
        let cs = CodeSwitchParameters()
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: enLM, parameters: p, secondary: sec, codeSwitch: cs)
        let ws = SwipeTuning.words(HinglishEvalSet.sentences(), en: en, hi: hi)
        var hiR: [String: SwipeScore] = [:]
        for (pi, profile) in SwipeProfile.all.enumerated() {
            var rng = SplitMix64(seed: 9300 + UInt64(pi))
            var s = SwipeScore()
            for w in ws {
                guard let pts = SwipeSynth.trace(w.word, layout: testLayout, profile: profile, rng: &rng) else { continue }
                let ctx = CodeSwitch.context(previousWords: w.previous, primary: en, secondary: sec, parameters: cs)
                s.add(truth: w.word, result: dec.decode(points: pts, context: ctx.primary, contextWords: w.previous,
                                                        secondaryContext: ctx.secondary))
            }
            hiR[profile.name] = s
        }
        return Report(en: enR, hi: hiR)
    }

    static func line(_ label: String, _ r: Report) -> String {
        func f(_ d: [String: SwipeScore], _ n: String) -> String {
            let s = d[n] ?? SwipeScore()
            return String(format: "%.1f/%.1f", s.top1Rate * 100, s.top3Rate * 100)
        }
        return "SWIPE3> \(label) | EN careful \(f(r.en, "careful")) normal \(f(r.en, "normal")) sloppy \(f(r.en, "sloppy"))"
            + " | HI careful \(f(r.hi, "careful")) normal \(f(r.hi, "normal")) sloppy \(f(r.hi, "sloppy")) (top1/top3 %)"
    }

    @Test func perProfileReport() throws {
        guard let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let r = Self.evaluate(SwipeParameters(), en: en, enLM: enLM, hi: hi, hiLM: hiLM)
        print(Self.line("current defaults", r))
        // Regression floors (synthetic).
        #expect((r.en["sloppy"]?.top1Rate ?? 0) >= 0.90)
        #expect((r.hi["sloppy"]?.top3Rate ?? 0) >= 0.93)
    }

    @Test func sweep() throws {
        guard ProcessInfo.processInfo.environment["IBOARD_SWEEP"] != nil else { return }
        guard let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        func run(_ label: String, _ mod: (inout SwipeParameters) -> Void) {
            var p = SwipeParameters()
            mod(&p)
            print(Self.line(label, Self.evaluate(p, en: en, enLM: enLM, hi: hi, hiLM: hiLM)))
        }
        run("baseline") { _ in }
        run("lmW .4 + locTol .35") { $0.lmWeight = 0.4; $0.locationTolerance = 0.35 }
        run("lmW .4 + locTol .35 + locSigma .3") { $0.lmWeight = 0.4; $0.locationTolerance = 0.35; $0.locationSigma = 0.3 }
        run("lmW .35 + locTol .3") { $0.lmWeight = 0.35; $0.locationTolerance = 0.3 }
    }
}
