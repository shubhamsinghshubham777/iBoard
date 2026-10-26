import CoreGraphics
import Foundation
import Testing
import IBoardEngine
import IBoardLayout

@Suite struct TapDecoderEditTests {
    let lex: Lexicon
    let lm: NGramModel
    let dec: TapDecoder

    init() throws {
        lex = try Fixture.small.lexicon()
        lm = try Fixture.small.model(lexicon: lex)
        dec = TapDecoder(layout: testLayout, lexicon: lex, model: lm)
    }

    @Test func transpositionsAreCorrected() throws {
        for (typed, intended) in [("teh", "the"), ("adn", "and"), ("hte", "the"), ("wrold", "world"), ("tomorrwo", "tomorrow")]
        where lex.lookup(intended) != nil {
            #expect(lex.lookup(typed) == nil, "\(typed) must be out of vocabulary for this test")
            let r = dec.decode(points: typed.map(centre))
            #expect(r.literal == typed)
            #expect(r.autocorrect?.word == intended, "\(typed) -> \(r.autocorrect?.word ?? "nil")")
            #expect(r.autocorrectConfidence > 0.97, "\(typed): confidence \(r.autocorrectConfidence)")
            #expect(r.candidates.first?.word == intended)
        }
    }

    @Test func missingLetterIsSuggested() throws {
        // "helo": hello is one missing letter away; it is offered, but not blindly applied.
        let r = dec.decode(points: "helo".map(centre))
        #expect(r.candidates.contains { $0.word == "hello" })
    }

    @Test func extraTapIsSuggested() throws {
        let r = dec.decode(points: "helllo".map(centre))
        #expect(r.candidates.contains { $0.word == "hello" })
    }

    @Test func validWordIsNeverTransposedAway() {
        // "form"/"from" style pairs: whichever is typed correctly must stay the best reading and not be corrected.
        for w in ["hello", "world", "going", "tomorrow", "the", "and"] {
            let r = dec.decode(points: w.map(centre))
            #expect(r.autocorrect == nil, "\(w)")
            #expect(r.candidates.first?.word == w)
        }
    }

    @Test func editsOffRestoresPlainBehaviour() {
        var p = TapDecoderParameters()
        p.enableEdits = false
        let plain = TapDecoder(layout: testLayout, lexicon: lex, model: lm, parameters: p)
        let r = plain.decode(points: "teh".map(centre))
        #expect(r.autocorrect?.word != "the")
    }

    @Test func deterministicWithEdits() {
        let pts = "tomorrwo".map(centre)
        let a = dec.decode(points: pts)
        for _ in 0..<5 { #expect(dec.decode(points: pts) == a) }
    }

    @Test func noisyTypingStillMeetsFalseCorrectionFloor() {
        // Noise-only typing (no real transpositions): corrections must stay rare for words typed as intended.
        var rng = SplitMix64(seed: 21)
        var wrong = 0, total = 0
        for id in 0..<UInt32(120) {
            let w = lex.word(of: id)
            guard w.count >= 3, w.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            for _ in 0..<10 {
                let r = dec.decode(points: trace(w, noise: 0.2, rng: &rng))
                total += 1
                if let a = r.autocorrect, a.word != w, r.autocorrectConfidence >= 0.97 { wrong += 1 }
            }
        }
        print("EDITFALSE high-confidence wrong corrections: \(wrong)/\(total)")
        #expect(Double(wrong) / Double(max(total, 1)) <= 0.02)
    }
}
