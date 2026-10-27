import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

// M7-04 Hinglish / code-switched eval. LEXICONS ARE REAL (Data/english + Data/hinglish, as the keyboard bundles them);
// the TEXT is a held-out, author-written set of 160 mixed sentences (Fixtures/eval/hinglish_mixed.txt, CC0) that is
// not used to build the data; the TOUCHES ARE SYNTHETIC (Gaussian tap noise / synthetic swipe traces). So these are
// honest about the language side and optimistic about the finger side. Skipped silently without Data/.

struct MixedWord {
    enum Lang: String, CaseIterable { case hinglish, english, both, oov }
    var word: String
    var previous: [String]
    var lang: Lang
}

enum HinglishEvalSet {
    static func sentences() -> [[String]] {
        let url = Bundle.module.url(forResource: "hinglish_mixed", withExtension: "txt", subdirectory: "Fixtures/eval")!
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(separator: " ").map(String.init) }
    }

    static func words(en: Lexicon, hi: Lexicon, minLength: Int = 2) -> [MixedWord] {
        var out: [MixedWord] = []
        for s in sentences() {
            for (i, w) in s.enumerated() where w.count >= minLength && w.allSatisfy({ $0.isASCII && $0.isLetter }) {
                let inEn = en.lookup(w) != nil, inHi = hi.lookup(w) != nil
                let lang: MixedWord.Lang = inEn && inHi ? .both : inHi ? .hinglish : inEn ? .english : .oov
                out.append(MixedWord(word: w, previous: Array(s[..<i].suffix(2)), lang: lang))
            }
        }
        return out
    }
}

@Suite struct HinglishEvalTests {
    static let noiseLevels: [Double] = [0.15, 0.25, 0.35]
    /// Each word is typed this many times with independent noise (more typos, tighter numbers).
    static let repetitions = 10

    @Test func evalSetIsHeldOutFromTheTrainingPhrases() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }   // file, Eval, IBoardEngineTests, Tests, IBoardEngine, Packages
        let train = url.appendingPathComponent("Tools/HinglishData/data/mixed_phrases.tsv")
        guard let text = try? String(contentsOf: train, encoding: .utf8) else { return }
        let trainSet = Set(text.split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { String($0.split(separator: "\t")[0]) })
        let overlap = HinglishEvalSet.sentences().map { $0.joined(separator: " ") }.filter { trainSet.contains($0) }
        #expect(overlap.isEmpty, "\(overlap)")
        #expect(HinglishEvalSet.sentences().count >= 130)
    }

    @Test func tapAutocorrectOnMixedText() async throws {
        guard let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let words = HinglishEvalSet.words(en: en, hi: hi)
        var census: [MixedWord.Lang: Int] = [:]
        for w in words { census[w.lang, default: 0] += 1 }
        print("=== M7-04 Hinglish eval: \(HinglishEvalSet.sentences().count) held-out sentences, \(words.count) distinct words x \(Self.repetitions) noisy typings "
              + "(hinglish-only \(census[.hinglish] ?? 0), english-only \(census[.english] ?? 0), both \(census[.both] ?? 0), "
              + "in neither lexicon \(census[.oov] ?? 0)); real lexicons, SYNTHETIC tap noise ===")
        print("targets = F2: top-1 correction precision >= 97%, false-correction <= 0.5%")
        let engine = EngineActor(layout: testLayout, lexicon: en, model: enLM, secondary: SecondaryLanguage(lexicon: hi, model: hiLM))
        var floorReports: [Double: EvalReport] = [:]
        for noise in Self.noiseLevels {
            var rng = SplitMix64(seed: 4040)
            var all: [EvalOutcome] = []
            var byLang: [MixedWord.Lang: [EvalOutcome]] = [:]
            var top3 = 0, top3Total = 0
            let state = AutocorrectState()
            for w in (0..<Self.repetitions).flatMap({ _ in words }) {
                let pts = trace(w.word, noise: noise, rng: &rng)
                guard let s = await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points(pts),
                                                                  previousWords: w.previous)) else { continue }
                let d = AutocorrectPolicy.decide(literal: s.literal, proposal: s.autocorrect, traits: AutocorrectTraits(), state: state)
                var applied: String?
                if case .correct(let to, _) = d { applied = to }
                let o = EvalOutcome(intended: w.word, literal: s.literal, applied: applied)
                all.append(o); byLang[w.lang, default: []].append(o)
                if w.lang != .oov {
                    top3Total += 1
                    if s.slots.contains(where: { $0.text == w.word }) || s.literal == w.word { top3 += 1 }
                }
            }
            let r = EvalScorer.score(all)
            floorReports[noise] = r
            print(line("noise \(noise)", r) + String(format: " | intended word shown or typed %.1f%% (in-vocab words)", Double(top3) / Double(max(top3Total, 1)) * 100))
            for lang in MixedWord.Lang.allCases { if let o = byLang[lang] { print("   " + line(lang.rawValue, EvalScorer.score(o))) } }
        }
        for (noise, r) in floorReports {
            #expect(r.items == HinglishEvalSet.words(en: en, hi: hi).count * Self.repetitions, "noise \(noise)")
            #expect(r.precision >= 0.85, "precision \(r.precision) at noise \(noise)")
            #expect(r.falseCorrectionRate <= 0.03, "false-correction \(r.falseCorrectionRate) at noise \(noise)")
        }
    }

    private func line(_ label: String, _ r: EvalReport) -> String {
        String(format: "%@: items %d typos %d applied %d | precision %.2f%% [%@] | false-correction %.2f%% [%@] | auto-fix recall %.1f%%",
               label, r.items, r.typos, r.appliedTotal, r.precision * 100, r.precision >= 0.97 ? "meets" : "BELOW",
               r.falseCorrectionRate * 100, r.falseCorrectionRate <= 0.005 ? "meets" : "ABOVE", r.recall * 100)
    }

    @Test func swipeOnMixedText() throws {
        guard let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let sec = SecondaryLanguage(lexicon: hi, model: hiLM)
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: enLM, secondary: sec)
        // Swipe needs a word of >= 3 letters with >= 2 distinct keys, and the word must exist in a lexicon.
        let words = HinglishEvalSet.words(en: en, hi: hi, minLength: 3).filter { $0.lang != .oov }
        print("=== M7-04 Hinglish SWIPE eval: \(words.count) in-vocabulary words (>=3 letters) from held-out sentences; real lexicons, SYNTHETIC traces ===")
        print("targets = F3: top-1 >= 90%, top-3 >= 97%")
        var floors: [String: SwipeScore] = [:]
        for (pi, profile) in SwipeProfile.all.enumerated() {
            var rng = SplitMix64(seed: 5000 + UInt64(pi))
            var score = SwipeScore()
            var byLang: [MixedWord.Lang: SwipeScore] = [:]
            for w in words {
                guard let pts = SwipeSynth.trace(w.word, layout: testLayout, profile: profile, rng: &rng) else { continue }
                let ctx = CodeSwitch.context(previousWords: w.previous, primary: en, secondary: sec, parameters: CodeSwitchParameters())
                let r = dec.decode(points: pts, context: ctx.primary, contextWords: w.previous, secondaryContext: ctx.secondary)
                score.add(truth: w.word, result: r)
                byLang[w.lang, default: SwipeScore()].add(truth: w.word, result: r)
            }
            print(score.line("mixed / \(profile.name) [top-1 \(score.top1Rate >= 0.9 ? "meets" : "BELOW"), top-3 \(score.top3Rate >= 0.97 ? "meets" : "BELOW")]"))
            for lang in MixedWord.Lang.allCases { if let s = byLang[lang] { print("   " + s.line("\(profile.name) / \(lang.rawValue)")) } }
            floors[profile.name] = score
        }
        for (name, s) in floors {
            #expect(s.total > 400, "\(name)")
            #expect(s.top1Rate >= 0.5, "\(name) top-1 \(s.top1Rate)")
            #expect(s.top3Rate >= 0.7, "\(name) top-3 \(s.top3Rate)")
        }
    }
}
