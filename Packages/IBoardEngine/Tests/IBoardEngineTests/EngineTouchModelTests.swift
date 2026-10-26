import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

@Suite struct EngineTouchModelTests {
    let lex: Lexicon
    let lm: NGramModel
    let ctx = TouchModelContext(orientation: .portrait, displayClass: .phone)
    let words = ["hello", "world", "going", "tomorrow", "the", "and", "with", "you", "that", "this", "have", "from"]

    init() throws {
        lex = try Fixture.small.lexicon()
        lm = try Fixture.small.model(lexicon: lex)
    }

    /// Touches of `word` with a constant bias (key units) plus noise.
    private func biased(_ word: String, dx: Double, dy: Double, noise: Double, rng: inout SplitMix64) -> [CGPoint] {
        word.map { ch -> CGPoint in
            let k = testLayout.firstKey(.letter(String(ch)))!
            return CGPoint(x: k.frame.midX + CGFloat(dx + rng.gaussian() * noise) * k.frame.width,
                           y: k.frame.midY + CGFloat(dy + rng.gaussian() * noise) * k.frame.height)
        }
    }

    private func trained(dx: Double, dy: Double) -> AdaptiveTouchModel {
        var m = AdaptiveTouchModel()
        var rng = SplitMix64(seed: 77)
        for r in 0..<300 {
            let w = words[r % words.count]
            let samples = w.map { ch -> TouchSample in
                TouchSample(key: .letter(String(ch)), dx: dx + rng.gaussian() * 0.12, dy: dy + rng.gaussian() * 0.12)
            }
            m.record(CommittedWordTouches(samples: samples, confidence: 0.97), in: ctx)
        }
        return m
    }

    private func literalHits(_ e: EngineActor, dx: Double, dy: Double, seed: UInt64) async -> (literal: Int, total: Int) {
        var rng = SplitMix64(seed: seed)
        var ok = 0, total = 0
        for _ in 0..<15 {
            for w in words {
                let pts = biased(w, dx: dx, dy: dy, noise: 0.12, rng: &rng)
                let s = await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points(pts)))
                total += 1
                if s?.literal == w { ok += 1 }
            }
        }
        return (ok, total)
    }

    @Test func learnedBiasImprovesDecodingAndNilRestoresBase() async throws {
        let (dx, dy) = (0.28, 0.0)   // taps land well right of the key centres
        let e = EngineActor(layout: testLayout, lexicon: lex, model: lm)
        let before = await literalHits(e, dx: dx, dy: dy, seed: 5)
        let model = trained(dx: dx, dy: dy)
        let n = await e.applyTouchModel(model, context: ctx)
        #expect(n > 10)
        // The literal is the nearest key per touch, so only the decoder's best candidate can change: use candidates.
        var rng = SplitMix64(seed: 5)
        var okBase = 0, okLearned = 0, total = 0
        var scoreBase = 0.0, scoreLearned = 0.0
        let base = TapDecoder(layout: testLayout, lexicon: lex, model: lm)
        var p = TapDecoderParameters()
        model.apply(to: &p, context: ctx)
        let learned = TapDecoder(layout: testLayout, lexicon: lex, model: lm, parameters: p)
        for _ in 0..<15 {
            for w in words {
                let pts = biased(w, dx: dx, dy: dy, noise: 0.12, rng: &rng)
                total += 1
                let rb = base.decode(points: pts), rl = learned.decode(points: pts)
                if rb.candidates.first?.word == w { okBase += 1 }
                if rl.candidates.first?.word == w { okLearned += 1 }
                if let b = rb.candidates.first(where: { $0.word == w }), let l = rl.candidates.first(where: { $0.word == w }) {
                    scoreBase += b.score
                    scoreLearned += l.score
                }
            }
        }
        #expect(okLearned >= okBase)
        // The intended word is more likely under the learned spatial model than under the neutral one.
        #expect(scoreLearned > scoreBase + 1, "learned \(scoreLearned) vs base \(scoreBase)")
        // Through the actor: the engine must now agree with the directly built learned decoder.
        var rng2 = SplitMix64(seed: 9)
        for w in words {
            let pts = biased(w, dx: dx, dy: dy, noise: 0.12, rng: &rng2)
            let s = try #require(await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points(pts))))
            let direct = learned.decode(points: pts)
            #expect(s.slots.dropFirst().first?.text == direct.candidates.first { !$0.isLiteral }?.word)
        }
        _ = before
        // Removing the model restores the base decoder.
        #expect(await e.applyTouchModel(nil, context: nil) == 0)
        let pts = biased("hello", dx: dx, dy: dy, noise: 0.05, rng: &rng)
        let s = try #require(await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points(pts))))
        let ref = base.decode(points: pts)
        #expect(s.literal == ref.literal)
        print("TOUCHMODEL intended-word score sum base \(scoreBase) learned \(scoreLearned); top-1 base \(okBase)/\(total), learned \(okLearned)/\(total)")
    }

    @Test func modelSurvivesLayoutUpdateAndContextSwitch() async throws {
        let e = EngineActor(layout: testLayout, lexicon: lex, model: lm)
        let model = trained(dx: 0.2, dy: 0.1)
        #expect(await e.applyTouchModel(model, context: ctx) > 10)
        await e.updateLayout(testLayout)
        // A context with no samples learns nothing.
        let other = TouchModelContext(orientation: .landscape, displayClass: .phone)
        #expect(await e.applyTouchModel(model, context: other) == 0)
        #expect(await e.applyTouchModel(model, context: ctx) > 10)
    }
}
