import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine

// M2-07 (real error side). REAL human misspellings from Wikipedia's "Lists of common misspellings" (Data/testsets/
// en_misspellings.tsv, CC BY-SA 4.0, see Data/testsets/LICENSE.md) against the REAL English lexicon + LM
// (Data/english) with the real Hinglish lexicon loaded as the secondary language, as the keyboard ships.
// Limits: these are spelling errors (mostly hard words), not slips of the finger, and there is no sentence context;
// each is typed at the key centres, so the touch side is noise-free. It complements, not replaces, the tap-noise eval.

func realMisspellings() -> [(typo: String, fix: String)]? {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    guard let text = try? String(contentsOf: url.appendingPathComponent("Data/testsets/en_misspellings.tsv"), encoding: .utf8) else { return nil }
    return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap {
        let p = $0.split(separator: "\t").map(String.init)
        return p.count == 2 ? (p[0], p[1]) : nil
    }
}

@Suite struct RealMisspellingEvalTests {
    @Test func realWorldMisspellings() async throws {
        guard let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish(), let pairs = realMisspellings() else { return }
        let engine = EngineActor(layout: testLayout, lexicon: en, model: enLM, secondary: SecondaryLanguage(lexicon: hi, model: hiLM))
        let usable = pairs.filter { en.lookup($0.fix) != nil && en.lookup($0.typo) == nil }
        let typoIsWord = pairs.filter { en.lookup($0.fix) != nil && en.lookup($0.typo) != nil }.count
        print("=== M2-07 REAL misspellings (Wikipedia, CC BY-SA 4.0): \(pairs.count) pairs, \(usable.count) usable "
              + "(correction in lexicon, typo not a lexicon word; \(typoIsWord) typos are themselves words and are skipped; "
              + "\(pairs.count - usable.count - typoIsWord) corrections missing from the lexicon) ===")
        let state = AutocorrectState()
        var outcomes: [EvalOutcome] = []
        var top3 = 0, top1Slot = 0
        for p in usable {
            guard let s = await engine.submit(EngineRequest(sequence: engine.beginRequest(),
                                                              touches: .points(p.typo.map(centre)))) else { continue }
            var applied: String?
            if case .correct(let to, _) = AutocorrectPolicy.decide(literal: s.literal, proposal: s.autocorrect, traits: AutocorrectTraits(), state: state) { applied = to }
            outcomes.append(EvalOutcome(intended: p.fix, literal: s.literal, applied: applied))
            let words = s.slots.map(\.text)
            if words.prefix(3).contains(p.fix) { top3 += 1 }
            if s.autocorrect?.word == p.fix { top1Slot += 1 }
        }
        // Control: the correct spellings typed exactly; any change is a false correction.
        var control: [EvalOutcome] = []
        for p in usable {
            guard let s = await engine.submit(EngineRequest(sequence: engine.beginRequest(),
                                                              touches: .points(p.fix.map(centre)))) else { continue }
            var applied: String?
            if case .correct(let to, _) = AutocorrectPolicy.decide(literal: s.literal, proposal: s.autocorrect, traits: AutocorrectTraits(), state: state) { applied = to }
            control.append(EvalOutcome(intended: p.fix, literal: s.literal, applied: applied))
        }
        let r = EvalScorer.score(outcomes), c = EvalScorer.score(control)
        let n = Double(max(outcomes.count, 1))
        print(String(format: "misspellings: n=%d | auto-applied %d | precision %.2f%% [F2 target 97%%] | auto-fix recall %.1f%% | engine's top proposal is the fix (before policy) %.1f%% | fix in top-3 %.1f%%",
                     r.items, r.appliedTotal, r.precision * 100, r.recall * 100, Double(top1Slot) / n * 100, Double(top3) / n * 100))
        print(String(format: "control (correct words typed exactly): n=%d | false-correction %.3f%% (%d) [F2 target 0.5%%]",
                     c.items, c.falseCorrectionRate * 100, c.falseCorrections))
        #expect(r.items > 1000)
        #expect(r.precision >= 0.8, "precision \(r.precision)")
        #expect(c.falseCorrectionRate <= 0.02, "false-correction \(c.falseCorrectionRate)")
    }
}
