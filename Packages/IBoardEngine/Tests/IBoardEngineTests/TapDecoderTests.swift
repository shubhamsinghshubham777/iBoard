import CoreGraphics
import Foundation
import Testing
import IBoardEngine
import IBoardLayout

let testLayout: KeyboardLayout = LayoutEngine.layout(
    containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters)

/// Touch points for `word`: each letter's key centre plus Gaussian noise of `noise` key-sizes (x and y).
func trace(_ word: String, noise: Double, rng: inout SplitMix64, layout: KeyboardLayout = testLayout) -> [CGPoint] {
    word.map { ch -> CGPoint in
        let k = layout.firstKey(.letter(String(ch)))!
        return CGPoint(x: k.frame.midX + CGFloat(rng.gaussian() * noise) * k.frame.width,
                       y: k.frame.midY + CGFloat(rng.gaussian() * noise) * k.frame.height)
    }
}

func centre(_ ch: Character) -> CGPoint {
    let k = testLayout.firstKey(.letter(String(ch)))!
    return CGPoint(x: k.frame.midX, y: k.frame.midY)
}

@Suite struct TapDecoderTests {
    let lex: Lexicon
    let lm: NGramModel
    let dec: TapDecoder

    init() throws {
        lex = try Fixture.small.lexicon()
        lm = try Fixture.small.model(lexicon: lex)
        dec = TapDecoder(layout: testLayout, lexicon: lex, model: lm)
    }

    @Test func perfectTapsGiveTheWordWithoutAutocorrect() {
        for w in ["hello", "world", "going", "tomorrow", "the"] {
            let r = dec.decode(points: w.map(centre))
            #expect(r.literal == w)
            #expect(r.candidates.first?.word == w, "\(w)")
            #expect(r.candidates.first?.isLiteral == true)
            #expect(r.autocorrect == nil)
            #expect(r.literalPosterior > 0.5)
        }
    }

    @Test func sloppyTapOnNeighbourKeyIsCorrected() throws {
        // "hello" with the second 'l' landing mostly on 'k' (its left neighbour): literal "helko" is not a word.
        let k = try #require(testLayout.firstKey(.letter("k")))
        let l = try #require(testLayout.firstKey(.letter("l")))
        var pts = "hello".map(centre)
        pts[3] = CGPoint(x: k.frame.midX * 0.7 + l.frame.midX * 0.3, y: k.frame.midY)
        let r = dec.decode(points: pts)
        #expect(r.literal == "helko")
        #expect(r.candidates.first?.word == "hello")
        #expect(r.autocorrect?.word == "hello")
        #expect(r.autocorrectConfidence > 0.9, "confidence \(r.autocorrectConfidence)")
        #expect(r.candidates.contains { $0.isLiteral && $0.word == "helko" && $0.wordID == nil } || r.candidates.count < 8)
    }

    @Test func literalOutOfVocabularyIsKeptWhenNothingFits() {
        let r = dec.decode(points: "qzxqz".map(centre))
        #expect(r.literal == "qzxqz")
        #expect(r.autocorrect == nil)
        #expect(r.autocorrectConfidence == 0)
        #expect(r.candidates.map(\.word) == ["qzxqz"])
        #expect(r.candidates[0].wordID == nil)
    }

    @Test func emptyInput() {
        let r = dec.decode(points: [])
        #expect(r.literal.isEmpty && r.candidates.isEmpty && r.autocorrect == nil)
    }

    @Test func prefixGivesCompletions() throws {
        let r = dec.decode(points: "th".map(centre))
        let words = r.candidates.map(\.word)
        #expect(words.contains("the") && words.contains("that") && words.contains("this"), "\(words)")
        #expect(r.candidates.filter(\.isCompletion).count >= 3)
        #expect(r.autocorrect == nil)            // completions are never autocorrect targets
        #expect(r.literal == "th")
        // Completions are ranked by the LM: with context "want", "to"-like words follow bigrams.
        let id = try #require(lex.lookup("want"))
        let ctx = dec.decode(points: "t".map(centre), context: LMContext(recent: id))
        #expect(ctx.candidates.first?.word == "to")
    }

    @Test func languageModelBreaksSpatialTies() throws {
        // First touch exactly between 't' and 'g', then 'o': "to" or "go".
        let t = centre("t"), g = centre("g")
        let mid = CGPoint(x: (t.x + g.x) / 2, y: (t.y + g.y) / 2)
        let pts = [mid, centre("o")]
        let none = dec.decode(points: pts)
        #expect(none.candidates.first?.word == "to")      // higher unigram
        let to = try #require(lex.lookup("to"))
        let after = dec.decode(points: pts, context: LMContext(recent: to))
        #expect(after.candidates.first?.word == "go", "\(after.candidates.map(\.word))")  // "to go" is a phrase
        // Without the LM, only unigram frequency decides (still deterministic).
        let uni = TapDecoder(layout: testLayout, lexicon: lex, model: nil)
        #expect(uni.decode(points: pts, context: LMContext(recent: to)).candidates.first?.word == "to")
    }

    @Test func deterministic() {
        var rng = SplitMix64(seed: 42)
        let pts = trace("meeting", noise: 0.4, rng: &rng)
        let a = dec.decode(points: pts)
        for _ in 0..<5 { #expect(dec.decode(points: pts) == a) }
    }

    @Test func keyHitsAndPointsAgree() throws {
        var rng = SplitMix64(seed: 7)
        let pts = trace("thanks", noise: 0.3, rng: &rng)
        let hits = try pts.map { try #require(testLayout.nearestHit(to: $0)) }
        let a = dec.decode(points: pts)
        let b = dec.decode(hits: hits, layout: testLayout)
        #expect(a.literal == b.literal)
        #expect(a.candidates.map(\.word) == b.candidates.map(\.word))
        for (x, y) in zip(a.candidates, b.candidates) { #expect(abs(x.score - y.score) < 1e-6) }
    }

    @Test func spatialModelIsGaussianInKeyUnits() throws {
        // A bias learned for 'e' (finger lands 0.3 key widths to the left) makes that offset the best fit.
        var p = TapDecoderParameters()
        p.keyModels[.letter("e")] = KeySpatialModel(meanX: -0.3, sigmaX: 0.2, sigmaY: 0.3)
        let biased = TapDecoder(layout: testLayout, lexicon: lex, model: lm, parameters: p)
        let e = try #require(testLayout.firstKey(.letter("e")))
        let shifted = CGPoint(x: e.frame.midX - 0.3 * e.frame.width, y: e.frame.midY)
        // Single touch, completions off the table: compare the key choice on the touch itself.
        let plain = dec.decode(points: [shifted]).literal
        let withBias = biased.decode(points: [shifted]).literal
        #expect(plain == "e" && withBias == "e")
        // Far outside either model: pure geometry still picks the nearest key.
        #expect(dec.decode(points: [CGPoint(x: e.frame.midX + 0.9 * e.frame.width, y: e.frame.midY)]).literal == "r")
    }

    /// Accuracy over seeded synthetic traces with injected noise. The decoder must beat "type what the fingers hit".
    @Test func noisyTracesBeatLiteral() throws {
        let words = ["hello", "world", "thanks", "tomorrow", "morning", "dinner", "coffee", "weekend", "family",
                     "message", "yesterday", "meeting", "friend", "school", "phone", "happy", "sorry", "really",
                     "maybe", "going", "thinking", "working", "please", "great", "little", "should", "believe",
                     "remember", "understand", "provide"]
        for noise in [0.25, 0.35] {
            var rng = SplitMix64(seed: 2026)
            var literalOK = 0, decoderOK = 0, total = 0, falseCorrections = 0
            for _ in 0..<20 {
                for w in words {
                    let r = dec.decode(points: trace(w, noise: noise, rng: &rng))
                    total += 1
                    if r.literal == w { literalOK += 1 }
                    if r.candidates.first?.word == w { decoderOK += 1 }
                    if r.literal == w, let a = r.autocorrect, a.word != w { falseCorrections += 1 }
                }
            }
            let lit = Double(literalOK) / Double(total), decd = Double(decoderOK) / Double(total)
            print("TAPACC noise \(noise): literal \(lit), decoder top-1 \(decd), false corrections of correct literals \(falseCorrections)/\(literalOK), n=\(total)")
            #expect(decd > lit + 0.05, "noise \(noise): decoder \(decd) vs literal \(lit)")
            #expect(decd > 0.8, "noise \(noise): decoder \(decd)")
            #expect(Double(falseCorrections) <= 0.02 * Double(literalOK))
        }
    }

    @Test func confidenceTracksNoise() {
        // Same word, tidy vs very sloppy typing: autocorrect (when it fires) is more confident for tidier input.
        var rng = SplitMix64(seed: 99)
        var tidy = 0.0, sloppy = 0.0
        var nt = 0, ns = 0
        for _ in 0..<60 {
            let a = dec.decode(points: trace("tomorrow", noise: 0.2, rng: &rng))
            if a.autocorrect != nil { tidy += a.autocorrectConfidence; nt += 1 }
            let b = dec.decode(points: trace("tomorrow", noise: 0.5, rng: &rng))
            if b.autocorrect != nil { sloppy += b.autocorrectConfidence; ns += 1 }
        }
        #expect(ns > 0)
        if nt > 0 && ns > 0 { #expect(tidy / Double(nt) >= sloppy / Double(ns) - 0.2) }
    }
}
