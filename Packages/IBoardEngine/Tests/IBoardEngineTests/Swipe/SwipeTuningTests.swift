import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

/// DATA2 tuning harness. Sentences of the Hinglish set are split by index parity into a TUNING half (even) and a
/// HELD-OUT half (odd). Parameters are chosen on the tuning half only; the held-out half is reported alongside.
/// Sweeps are opt-in (IBOARD_TUNE=1) so the normal test run stays fast. Traces are SYNTHETIC.
enum SwipeTuning {
    struct Split { var tune: [[String]]; var held: [[String]] }

    static func split() -> Split {
        let all = HinglishEvalSet.sentences()
        var t: [[String]] = [], h: [[String]] = []
        for (i, s) in all.enumerated() { if i % 2 == 0 { t.append(s) } else { h.append(s) } }
        return Split(tune: t, held: h)
    }

    static func words(_ sentences: [[String]], en: Lexicon, hi: Lexicon) -> [MixedWord] {
        var out: [MixedWord] = []
        for s in sentences {
            for (i, w) in s.enumerated() where w.count >= 3 && w.allSatisfy({ $0.isASCII && $0.isLetter }) {
                let inEn = en.lookup(w) != nil, inHi = hi.lookup(w) != nil
                if !inEn && !inHi { continue }
                let lang: MixedWord.Lang = inEn && inHi ? .both : inHi ? .hinglish : .english
                out.append(MixedWord(word: w, previous: Array(s[..<i].suffix(2)), lang: lang))
            }
        }
        return out
    }

    /// Score one word set over all three profiles, `reps` independent traces per word.
    static func score(_ ws: [MixedWord], dec: SwipeDecoder, en: Lexicon, sec: SecondaryLanguage,
                      cs: CodeSwitchParameters, reps: Int, seedBase: UInt64) -> (all: SwipeScore, hi: SwipeScore) {
        var all = SwipeScore(), hi = SwipeScore()
        for (pi, profile) in SwipeProfile.all.enumerated() {
            var rng = SplitMix64(seed: seedBase + UInt64(pi))
            for _ in 0..<reps {
                for w in ws {
                    guard let pts = SwipeSynth.trace(w.word, layout: testLayout, profile: profile, rng: &rng) else { continue }
                    let ctx = CodeSwitch.context(previousWords: w.previous, primary: en, secondary: sec, parameters: cs)
                    let r = dec.decode(points: pts, context: ctx.primary, contextWords: w.previous, secondaryContext: ctx.secondary)
                    all.add(truth: w.word, result: r)
                    if w.lang == .hinglish { hi.add(truth: w.word, result: r) }
                }
            }
        }
        return (all, hi)
    }
}

@Suite struct SwipeTuningTests {
    @Test func sweep() throws {
        guard ProcessInfo.processInfo.environment["IBOARD_TUNE"] != nil else { return }
        guard let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let sec = SecondaryLanguage(lexicon: hi, model: hiLM)
        let sp = SwipeTuning.split()
        let tw = SwipeTuning.words(sp.tune, en: en, hi: hi), hw = SwipeTuning.words(sp.held, en: en, hi: hi)
        print("TUNE words \(tw.count), HELD words \(hw.count)")
        func run(_ label: String, _ mod: (inout SwipeParameters, inout CodeSwitchParameters) -> Void) {
            var p = SwipeParameters(), c = CodeSwitchParameters()
            mod(&p, &c)
            let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: enLM, parameters: p, secondary: sec, codeSwitch: c)
            let t = SwipeTuning.score(tw, dec: dec, en: en, sec: sec, cs: c, reps: 2, seedBase: 9100)
            let h = SwipeTuning.score(hw, dec: dec, en: en, sec: sec, cs: c, reps: 2, seedBase: 9200)
            print(String(format: "TUNE> %@ | TUNE t1 %.2f t3 %.2f (hi t1 %.2f) | HELD t1 %.2f t3 %.2f (hi t1 %.2f)", label,
                         t.all.top1Rate * 100, t.all.top3Rate * 100, t.hi.top1Rate * 100,
                         h.all.top1Rate * 100, h.all.top3Rate * 100, h.hi.top1Rate * 100))
        }
        run("baseline") { _, _ in }
        func base(_ p: inout SwipeParameters, _ c: inout CodeSwitchParameters) { p.lmUnigramMix = 0.3; p.lmWeight = 0.5 }
        run("base mix.3 lmW.5") { p, c in base(&p, &c) }
        for v in [0.4, 0.6] { run("base lmW \(v)") { p, c in base(&p, &c); p.lmWeight = v } }
        for v in [0.5, 0.8] { run("base mix \(v)") { p, c in base(&p, &c); p.lmUnigramMix = v } }
        for v in [1.0, 2.0] { run("base priorWeight \(v)") { p, c in base(&p, &c); c.priorWeight = v } }
        for v in [0.25, 0.3] { run("base locationSigma \(v)") { p, c in base(&p, &c); p.locationSigma = v } }
        for v in [0.75, 1.0] { run("base anchorWeight \(v)") { p, c in base(&p, &c); p.anchorWeight = v } }
        for v in [0.07] { run("base shapeSigma \(v)") { p, c in base(&p, &c); p.shapeSigma = v } }
    }

    /// Prints the words that fail top-1 on the tuning half (normal profile), for diagnosis.
    @Test func failures() throws {
        guard ProcessInfo.processInfo.environment["IBOARD_TUNE_FAIL"] != nil else { return }
        guard let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let sec = SecondaryLanguage(lexicon: hi, model: hiLM)
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: enLM, secondary: sec)
        let tw = SwipeTuning.words(SwipeTuning.split().tune, en: en, hi: hi)
        var rng = SplitMix64(seed: 9100 + 1)
        var n = 0
        for w in tw {
            guard let pts = SwipeSynth.trace(w.word, layout: testLayout, profile: .normal, rng: &rng) else { continue }
            let ctx = CodeSwitch.context(previousWords: w.previous, primary: en, secondary: sec, parameters: CodeSwitchParameters())
            let r = dec.decode(points: pts, context: ctx.primary, contextWords: w.previous, secondaryContext: ctx.secondary)
            if r.candidates.first?.word != w.word {
                let truth = r.candidates.first { $0.word == w.word }
                n += 1
                print(String(format: "FAIL> %@ [%@] got %@ | truth sp %.1f lm %.1f | top sp %.1f lm %.1f side %d",
                             w.word, w.lang.rawValue, r.candidates.first?.word ?? "-", truth?.spatial ?? .nan, truth?.language ?? .nan,
                             r.candidates.first?.spatial ?? .nan, r.candidates.first?.language ?? .nan,
                             Int(r.candidates.first?.side.rawValue ?? 9)))
            }
        }
        print("FAIL> total \(n) of \(tw.count)")
    }

    /// English regression: real English lexicon, no secondary language, top-5000 words, old vs tuned parameters.
    @Test func englishRegression() throws {
        guard let (en, enLM) = realEnglish() else { return }
        var old = SwipeParameters(); old.lmWeight = 1.0; old.lmUnigramMix = 0
        func run(_ p: SwipeParameters) -> SwipeScore {
            let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: enLM, parameters: p)
            var all = SwipeScore()
            for (pi, profile) in SwipeProfile.all.enumerated() {
                var rng = SplitMix64(seed: 3100 + UInt64(pi))
                for w in swipeSampleWords(en, upTo: 5000, count: 500, seed: 31 + UInt64(pi)) {
                    guard let pts = SwipeSynth.trace(w, layout: testLayout, profile: profile, rng: &rng) else { continue }
                    all.add(truth: w, result: dec.decode(points: pts))
                }
            }
            return all
        }
        let a = run(old), b = run(SwipeParameters())
        print(a.line("English real lexicon, OLD params (lmW 1.0, mix 0)"))
        print(b.line("English real lexicon, NEW params (current defaults)"))
        #expect(b.top1Rate >= a.top1Rate - 0.01)
        #expect(b.top3Rate >= a.top3Rate - 0.01)
    }
}
