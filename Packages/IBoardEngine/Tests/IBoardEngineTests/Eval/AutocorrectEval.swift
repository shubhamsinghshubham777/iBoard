import CoreGraphics
import Foundation
import Testing
import IBoardEngine
import IBoardLayout

// M2-07 eval harness. ALL DATA HERE IS SYNTHETIC: intended words are drawn (frequency weighted) from the 219-word
// synthetic fixture lexicon and "typed" with Gaussian touch noise around the key centres; the decoder's own spatial
// model is also Gaussian, so these numbers are optimistic and are NOT evidence for the F2 targets on real typing.
// They exist to catch regressions and to give the scorer a home until a real, consented eval set exists.

/// One evaluated word: what the user meant, what was under the fingers, and what the policy did.
struct EvalOutcome: Equatable {
    var intended: String
    var literal: String
    /// The word the policy auto-applied, nil when it kept the literal.
    var applied: String?
}

struct EvalReport: Equatable {
    var items = 0
    var typos = 0                    // literal != intended
    var appliedTotal = 0             // auto-corrections applied (right or wrong)
    var appliedCorrect = 0           // applied == intended on a typo
    var falseCorrections = 0         // applied on a word the user typed as intended
    var typedAsIntended = 0          // literal == intended (denominator of the false-correction rate)

    /// Top-1 correction precision: share of applied corrections that restored the intended word.
    var precision: Double { appliedTotal == 0 ? 1 : Double(appliedCorrect) / Double(appliedTotal) }
    /// Share of typed-as-intended words that were wrongly changed.
    var falseCorrectionRate: Double { typedAsIntended == 0 ? 0 : Double(falseCorrections) / Double(typedAsIntended) }
    /// Share of typos that were automatically fixed correctly.
    var recall: Double { typos == 0 ? 0 : Double(appliedCorrect) / Double(typos) }
}

enum EvalScorer {
    static func score(_ outcomes: [EvalOutcome]) -> EvalReport {
        var r = EvalReport()
        for o in outcomes {
            r.items += 1
            let isTypo = o.literal != o.intended
            if isTypo { r.typos += 1 } else { r.typedAsIntended += 1 }
            guard let a = o.applied else { continue }
            r.appliedTotal += 1
            if !isTypo { r.falseCorrections += 1 } else if a == o.intended { r.appliedCorrect += 1 }
        }
        return r
    }
}

/// Weighted sampling of the intended words plus a synthetic out-of-vocabulary set.
struct EvalSet {
    var inVocabulary: [String]
    var outOfVocabulary: [String]

    static func generate(words: [(String, Double)], count: Int, oovCount: Int, seed: UInt64) -> EvalSet {
        var rng = SplitMix64(seed: seed)
        let total = words.reduce(0) { $0 + $1.1 }
        var inVocab: [String] = []
        for _ in 0..<count {
            var x = Double(rng.next() >> 11) / Double(1 << 53) * total
            for (w, c) in words {
                x -= c
                if x <= 0 { inVocab.append(w); break }
            }
        }
        // Pseudo-names from random consonant-vowel syllables (3-4 syllables): never in the lexicon.
        let cons = Array("bdfgjklmnprstvz"), vowels = Array("aeiou")
        var oov: [String] = []
        while oov.count < oovCount {
            var w = ""
            for _ in 0..<(3 + Int(rng.next() % 2)) {
                w.append(cons[Int(rng.next() % UInt64(cons.count))])
                w.append(vowels[Int(rng.next() % UInt64(vowels.count))])
            }
            oov.append(w)
        }
        return EvalSet(inVocabulary: inVocab, outOfVocabulary: oov)
    }
}

@Suite struct EvalScorerTests {
    @Test func scorerArithmetic() {
        let report = EvalScorer.score([
            EvalOutcome(intended: "the", literal: "teh", applied: "the"),     // right fix
            EvalOutcome(intended: "the", literal: "tge", applied: "the"),     // right fix
            EvalOutcome(intended: "hello", literal: "helko", applied: "hells"), // wrong fix
            EvalOutcome(intended: "world", literal: "worod", applied: nil),   // missed
            EvalOutcome(intended: "form", literal: "form", applied: "from"),  // false correction
            EvalOutcome(intended: "love", literal: "love", applied: nil),     // fine
        ])
        #expect(report.items == 6 && report.typos == 4 && report.typedAsIntended == 2)
        #expect(report.appliedTotal == 4 && report.appliedCorrect == 2 && report.falseCorrections == 1)
        #expect(report.precision == 0.5)
        #expect(report.recall == 0.5)
        #expect(report.falseCorrectionRate == 0.5)
    }

    @Test func emptyDenominatorsAreSafe() {
        let r = EvalScorer.score([])
        #expect(r.precision == 1 && r.recall == 0 && r.falseCorrectionRate == 0)
    }

    @Test func evalSetIsDeterministicAndWeighted() {
        let words: [(String, Double)] = [("a", 90), ("b", 10)]
        let s1 = EvalSet.generate(words: words, count: 1000, oovCount: 5, seed: 7)
        let s2 = EvalSet.generate(words: words, count: 1000, oovCount: 5, seed: 7)
        #expect(s1.inVocabulary == s2.inVocabulary && s1.outOfVocabulary == s2.outOfVocabulary)
        let a = s1.inVocabulary.filter { $0 == "a" }.count
        #expect(a > 850 && a < 950)
        #expect(Set(s1.outOfVocabulary).count >= 1 && s1.outOfVocabulary.allSatisfy { $0.count >= 6 })
    }
}

@Suite struct AutocorrectEvalTests {
    /// Gaussian touch noise levels in key sizes: careful / typical / sloppy (decoder assumes 0.30).
    static let noiseLevels: [Double] = [0.15, 0.25, 0.35]
    static let precisionTarget = 0.97, falseCorrectionTarget = 0.005

    func loadWords() throws -> [(String, Double)] {
        let url = Fixture.small.url("uni", "tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t")
            guard p.count == 2, p[0].count >= 3, p[0].allSatisfy({ $0.isLetter }), let c = Double(p[1]) else { return nil }
            return (String(p[0]), c)
        }
    }

    func run(noise: Double, set: EvalSet, engine: EngineActor, seed: UInt64) async -> [EvalOutcome] {
        var rng = SplitMix64(seed: seed)
        var outcomes: [EvalOutcome] = []
        let state = AutocorrectState()
        for w in set.inVocabulary + set.outOfVocabulary {
            let pts = trace(w, noise: noise, rng: &rng)
            guard let s = await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points(pts))) else { continue }
            let d = AutocorrectPolicy.decide(literal: s.literal, proposal: s.autocorrect, traits: AutocorrectTraits(), state: state)
            var applied: String?
            if case .correct(let to, _) = d { applied = to }
            outcomes.append(EvalOutcome(intended: w, literal: s.literal, applied: applied))
        }
        return outcomes
    }

    @Test func syntheticF2Report() async throws {
        let lex = try Fixture.small.lexicon()
        let lm = try Fixture.small.model(lexicon: lex)
        let engine = EngineActor(layout: testLayout, lexicon: lex, model: lm)
        let set = EvalSet.generate(words: try loadWords(), count: 3000, oovCount: 500, seed: 2027)

        print("=== M2-07 SYNTHETIC autocorrect eval (219-word synthetic lexicon, Gaussian tap noise; NOT real typing) ===")
        print("targets (F2): top-1 correction precision >= \(Self.precisionTarget * 100)%, false-correction rate <= \(Self.falseCorrectionTarget * 100)%")
        var reports: [Double: EvalReport] = [:]
        for noise in Self.noiseLevels {
            let r = EvalScorer.score(await run(noise: noise, set: set, engine: engine, seed: 99))
            reports[noise] = r
            let p = String(format: "%.2f", r.precision * 100), f = String(format: "%.2f", r.falseCorrectionRate * 100)
            let rc = String(format: "%.1f", r.recall * 100)
            print("noise \(noise) key sizes: items \(r.items), typos \(r.typos), applied \(r.appliedTotal) | precision \(p)% [\(r.precision >= Self.precisionTarget ? "meets" : "BELOW") target] | false-correction \(f)% [\(r.falseCorrectionRate <= Self.falseCorrectionTarget ? "meets" : "ABOVE") target] | auto-fix recall \(rc)%")
        }
        // Regression floors only (not the F2 acceptance claim): the pipeline must be clearly working.
        for (noise, r) in reports {
            #expect(r.items == 3500, "noise \(noise)")
            #expect(r.typos > 0)
            #expect(r.precision >= 0.9, "precision \(r.precision) at noise \(noise)")
            #expect(r.falseCorrectionRate <= 0.02, "false-correction \(r.falseCorrectionRate) at noise \(noise)")
        }
    }
}
