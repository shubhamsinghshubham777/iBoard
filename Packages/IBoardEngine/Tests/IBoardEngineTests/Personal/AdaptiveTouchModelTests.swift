import CoreGraphics
import Foundation
import Testing
import IBoardLayout
@testable import IBoardEngine

private let ctxPortrait = TouchModelContext(orientation: .portrait, displayClass: .phone)
private let ctxLandscape = TouchModelContext(orientation: .landscape, displayClass: .phone)

private let words = ["hello", "world", "going", "tomorrow", "quick", "brown", "jumps", "over", "lazy", "dogs",
                    "keyboard", "typing", "morning", "please", "thanks", "meeting", "weekend", "zebra", "extra", "vivid"]

private struct Typist {
    /// Constant thumb bias plus a left/right dependent horizontal bias, in key units.
    var biasX: Double
    var biasY: Double
    var sideX: Double
    var noise: Double

    func touch(_ ch: Character, rng: inout SplitMix64) -> (letter: String, dx: Double, dy: Double) {
        let k = testLayout.firstKey(.letter(String(ch)))!
        let side = k.frame.midX < testLayout.keys.map(\.frame.midX).reduce(0, +) / Double(testLayout.keys.count) ? 1.0 : -1.0
        return (String(ch), biasX + side * sideX + rng.gaussian() * noise, biasY + rng.gaussian() * noise)
    }
}

/// Classifies a touch (offset from `intended`'s centre) by the decoder's spatial formula; returns the winning letter.
private func classify(dx: Double, dy: Double, intended: String, models: [KeyIdentity: KeySpatialModel]) -> String {
    let k0 = testLayout.firstKey(.letter(intended))!
    let px = k0.frame.midX + dx * k0.frame.width
    let py = k0.frame.midY + dy * k0.frame.height
    var best = (-Double.infinity, "")
    for k in testLayout.keys {
        guard case .letter(let l) = k.identity else { continue }
        let m = models[k.identity] ?? KeySpatialModel(sigmaX: 0.30, sigmaY: 0.30)
        let ux = ((px - k.frame.midX) / k.frame.width - m.meanX) / m.sigmaX
        let uy = ((py - k.frame.midY) / k.frame.height - m.meanY) / m.sigmaY
        let ll = -0.5 * (ux * ux + uy * uy) - log(m.sigmaX * m.sigmaY)
        if ll > best.0 { best = (ll, l) }
    }
    return best.1
}

private func train(_ model: inout AdaptiveTouchModel, typist: Typist, rounds: Int, seed: UInt64, in ctx: TouchModelContext) {
    var rng = SplitMix64(seed: seed)
    for r in 0..<rounds {
        let w = words[r % words.count]
        let samples = w.map { ch -> TouchSample in
            let t = typist.touch(ch, rng: &rng)
            return TouchSample(key: .letter(t.letter), dx: t.dx, dy: t.dy)
        }
        model.record(CommittedWordTouches(samples: samples, confidence: 0.97), in: ctx)
    }
}

private func errorRate(typist: Typist, models: [KeyIdentity: KeySpatialModel], seed: UInt64) -> Double {
    var rng = SplitMix64(seed: seed)
    var wrong = 0, total = 0
    for _ in 0..<400 {
        for w in words {
            for ch in w {
                let t = typist.touch(ch, rng: &rng)
                if classify(dx: t.dx, dy: t.dy, intended: t.letter, models: models) != t.letter { wrong += 1 }
                total += 1
            }
        }
    }
    return Double(wrong) / Double(total)
}

@Suite struct AdaptiveTouchModelTests {
    @Test func sloppyTypingReducesRawKeyErrorsByAtLeast15Percent() {
        let sloppy = Typist(biasX: 0.0, biasY: 0.22, sideX: 0.14, noise: 0.27)
        var model = AdaptiveTouchModel()
        train(&model, typist: sloppy, rounds: 300, seed: 1, in: ctxPortrait)   // about 1,800 letters
        let before = errorRate(typist: sloppy, models: [:], seed: 99)
        let after = errorRate(typist: sloppy, models: model.keyModels(for: ctxPortrait), seed: 99)
        let reduction = (before - after) / before
        print("sloppy raw key-error rate before \(before) after \(after) reduction \(reduction)")
        #expect(before > 0.05)
        #expect(reduction >= 0.15, "reduction \(reduction)")
    }

    @Test func neutralTypistIsNotHarmed() {
        let neutral = Typist(biasX: 0, biasY: 0, sideX: 0, noise: 0.20)
        var model = AdaptiveTouchModel()
        train(&model, typist: neutral, rounds: 300, seed: 2, in: ctxPortrait)
        let before = errorRate(typist: neutral, models: [:], seed: 7)
        let after = errorRate(typist: neutral, models: model.keyModels(for: ctxPortrait), seed: 7)
        print("neutral raw key-error rate before \(before) after \(after)")
        #expect(after <= before + 0.002, "before \(before) after \(after)")
        for (_, m) in model.keyModels(for: ctxPortrait) { #expect(abs(m.meanX) < 0.08 && abs(m.meanY) < 0.08) }
    }

    @Test func gatingIgnoresCorrectedRestoredAndLowConfidenceWords() {
        var model = AdaptiveTouchModel()
        let s = [TouchSample(key: .letter("a"), dx: 0.2, dy: 0.1), TouchSample(key: .letter("b"), dx: 0.2, dy: 0.1)]
        #expect(model.record(CommittedWordTouches(samples: s, confidence: 0.99, wasCorrected: true), in: ctxPortrait) == .corrected)
        #expect(model.record(CommittedWordTouches(samples: s, confidence: 0.99, wasRestored: true), in: ctxPortrait) == .restored)
        #expect(model.record(CommittedWordTouches(samples: s, confidence: 0.5), in: ctxPortrait) == .lowConfidence)
        #expect(model.record(CommittedWordTouches(samples: [s[0]], confidence: 0.99), in: ctxPortrait) == .tooShort)
        #expect(model.sampleCount(in: ctxPortrait) == 0)
        #expect(model.record(CommittedWordTouches(samples: s, confidence: 0.95), in: ctxPortrait) == nil)
        #expect(model.sampleCount(in: ctxPortrait) == 2)
    }

    @Test func outliersAndNonLettersAreIgnored() {
        var model = AdaptiveTouchModel()
        let s = [TouchSample(key: .letter("a"), dx: 0.9, dy: 0), TouchSample(key: .space, dx: 0, dy: 0),
                 TouchSample(key: .letter("b"), dx: .nan, dy: 0)]
        #expect(model.record(CommittedWordTouches(samples: s, confidence: 0.99), in: ctxPortrait) == .noUsableSamples)
        #expect(model.sampleCount(in: ctxPortrait) == 0)
    }

    @Test func shiftIsClampedToThirtyPercent() {
        var model = AdaptiveTouchModel()
        var config = AdaptiveTouchConfig(); config.priorStrength = 0   // no shrinkage so the clamp is what limits
        model.config = config
        for _ in 0..<50 {
            model.record(CommittedWordTouches(samples: [TouchSample(key: .letter("a"), dx: 0.7, dy: -0.7),
                                                        TouchSample(key: .letter("a"), dx: 0.7, dy: -0.7)],
                                              confidence: 0.99), in: ctxPortrait)
        }
        let m = model.keyModels(for: ctxPortrait)[.letter("a")]
        #expect(m != nil)
        #expect(abs((m?.meanX ?? 0) - 0.3) < 1e-9)
        #expect(abs((m?.meanY ?? 0) + 0.3) < 1e-9)
    }

    @Test func fewSamplesAreShrunkAndSigmaStaysInBounds() {
        var model = AdaptiveTouchModel()
        for _ in 0..<2 {
            model.record(CommittedWordTouches(samples: [TouchSample(key: .letter("a"), dx: 0.4, dy: 0),
                                                        TouchSample(key: .letter("a"), dx: 0.4, dy: 0)],
                                              confidence: 0.99), in: ctxPortrait)
        }
        // 4 samples: lambda = 4/16 = 0.25, mean 0.4 -> 0.1
        let m = model.keyModels(for: ctxPortrait)[.letter("a")]!
        #expect(abs(m.meanX - 0.1) < 1e-9)
        #expect(m.sigmaX >= 0.18 && m.sigmaX <= 0.42 && m.sigmaY >= 0.18 && m.sigmaY <= 0.42)
    }

    @Test func contextsAreSeparate() {
        var model = AdaptiveTouchModel()
        train(&model, typist: Typist(biasX: 0.2, biasY: 0.2, sideX: 0, noise: 0.2), rounds: 60, seed: 3, in: ctxPortrait)
        #expect(!model.keyModels(for: ctxPortrait).isEmpty)
        #expect(model.keyModels(for: ctxLandscape).isEmpty)
        #expect(model.keyModels(for: TouchModelContext(orientation: .portrait, displayClass: .duoInner)).isEmpty)
        train(&model, typist: Typist(biasX: -0.2, biasY: 0, sideX: 0, noise: 0.2), rounds: 60, seed: 4, in: ctxLandscape)
        let p = model.keyModels(for: ctxPortrait)[.letter("o")]!, l = model.keyModels(for: ctxLandscape)[.letter("o")]!
        #expect(p.meanX > 0.05 && l.meanX < -0.05)
    }

    @Test func resetClearsOneContextOrAll() {
        var model = AdaptiveTouchModel()
        let t = Typist(biasX: 0.2, biasY: 0, sideX: 0, noise: 0.2)
        train(&model, typist: t, rounds: 40, seed: 5, in: ctxPortrait)
        train(&model, typist: t, rounds: 40, seed: 6, in: ctxLandscape)
        model.reset(ctxPortrait)
        #expect(model.keyModels(for: ctxPortrait).isEmpty && !model.keyModels(for: ctxLandscape).isEmpty)
        model.resetAll()
        #expect(model.keyModels(for: ctxLandscape).isEmpty)
    }

    @Test func emaFollowsAChangingTypist() {
        var model = AdaptiveTouchModel()
        train(&model, typist: Typist(biasX: 0.25, biasY: 0, sideX: 0, noise: 0.15), rounds: 200, seed: 8, in: ctxPortrait)
        let first = model.keyStats("e", in: ctxPortrait)!.meanX
        train(&model, typist: Typist(biasX: -0.25, biasY: 0, sideX: 0, noise: 0.15), rounds: 600, seed: 9, in: ctxPortrait)
        let later = model.keyStats("e", in: ctxPortrait)!.meanX
        #expect(first > 0.15)
        #expect(later < -0.1, "mean \(later)")
    }

    @Test func persistenceRoundTripAndValidation() throws {
        var model = AdaptiveTouchModel()
        train(&model, typist: Typist(biasX: 0.1, biasY: 0.2, sideX: 0.05, noise: 0.25), rounds: 80, seed: 10, in: ctxPortrait)
        let data = AdaptiveTouchCodec.encode(model)
        let back = try AdaptiveTouchCodec.decode(data)
        #expect(back.stats == model.stats)
        #expect(back.keyModels(for: ctxPortrait) == model.keyModels(for: ctxPortrait))
        // The payload holds no text, only per-letter aggregates.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"version\":1"))

        #expect(throws: AdaptiveTouchCodecError.unsupportedVersion(2)) {
            try AdaptiveTouchCodec.decode(Data(#"{"version":2,"models":[]}"#.utf8))
        }
        #expect(throws: AdaptiveTouchCodecError.malformed) { try AdaptiveTouchCodec.decode(Data("not json".utf8)) }
        #expect(throws: AdaptiveTouchCodecError.tooLarge) {
            try AdaptiveTouchCodec.decode(Data(repeating: 0x20, count: AdaptiveTouchCodec.maxBytes + 1))
        }
        // Hostile numbers are clamped / dropped.
        let hostile = #"{"version":1,"models":[{"orientation":"portrait","displayClass":"phone","keys":[{"k":"a","n":5,"mx":99,"my":-99,"sxx":1e9,"sxy":0,"syy":-4},{"k":"bb","n":5,"mx":0,"my":0,"sxx":0,"sxy":0,"syy":0},{"k":"c","n":-1,"mx":0,"my":0,"sxx":0,"sxy":0,"syy":0}]}]}"#
        let h = try AdaptiveTouchCodec.decode(Data(hostile.utf8))
        let a = try #require(h.keyModels(for: ctxPortrait)[.letter("a")])
        #expect(a.meanX <= 0.3 && a.meanY >= -0.3 && a.sigmaX <= 0.42 && a.sigmaY >= 0.18)
        #expect(h.keyModels(for: ctxPortrait).count == 1)
    }

    @Test func fileStoreToleratesMissingAndCorruptFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iboard-touch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AdaptiveTouchFileStore(url: dir.appendingPathComponent("touch.json"))
        #expect(store.load().stats.isEmpty)
        var model = AdaptiveTouchModel()
        train(&model, typist: Typist(biasX: 0.1, biasY: 0, sideX: 0, noise: 0.2), rounds: 30, seed: 11, in: ctxPortrait)
        try store.save(model)
        #expect(store.load().stats == model.stats)
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load().stats.isEmpty)
        store.delete()
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func adapterFeedsTheTapDecoder() throws {
        let lex = try Fixture.small.lexicon()
        let lm = try Fixture.small.model(lexicon: lex)
        let sloppy = Typist(biasX: 0.0, biasY: 0.25, sideX: 0.0, noise: 0.05)
        var model = AdaptiveTouchModel()
        train(&model, typist: sloppy, rounds: 200, seed: 12, in: ctxPortrait)
        var params = TapDecoderParameters()
        model.apply(to: &params, context: ctxPortrait)
        #expect(!params.keyModels.isEmpty)
        let dec = TapDecoder(layout: testLayout, lexicon: lex, model: lm, parameters: params)
        // "hello" tapped a quarter key low: with the learned shift the literal is the intended word.
        let pts = "hello".map { ch -> CGPoint in
            let k = testLayout.firstKey(.letter(String(ch)))!
            return CGPoint(x: k.frame.midX, y: k.frame.midY + 0.25 * k.frame.height)
        }
        #expect(dec.decode(points: pts).literal == "hello")
    }
}
