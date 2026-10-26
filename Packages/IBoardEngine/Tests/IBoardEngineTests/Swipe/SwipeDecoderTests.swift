import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

/// Straight-line swipe through the key centres at constant speed.
func centreSwipe(_ word: String, layout: KeyboardLayout = testLayout) -> [SwipePoint] {
    var keys: [KeyboardKey] = []
    for ch in word { let k = layout.firstKey(.letter(String(ch)))!; if keys.last?.id != k.id { keys.append(k) } }
    var out: [SwipePoint] = []
    var t = 0.0
    for i in 0..<(keys.count - 1) {
        let a = keys[i].frame, b = keys[i + 1].frame
        for s in 0..<8 {
            let f = Double(s) / 8
            out.append(SwipePoint(x: Double(a.midX) + (Double(b.midX) - Double(a.midX)) * f,
                                  y: Double(a.midY) + (Double(b.midY) - Double(a.midY)) * f, t: t))
            t += 0.016
        }
    }
    out.append(SwipePoint(x: Double(keys.last!.frame.midX), y: Double(keys.last!.frame.midY), t: t))
    return out
}

@Suite struct SwipeDecoderTests {
    let lex: Lexicon
    let lm: NGramModel
    let dec: SwipeDecoder

    init() throws {
        lex = try Fixture.small.lexicon()
        lm = try Fixture.small.model(lexicon: lex)
        dec = SwipeDecoder(layout: testLayout, lexicon: lex, model: lm)
    }

    private func letterWords(min: Int = 3) -> [String] {
        (0..<lex.wordCount).map { lex.word(of: UInt32($0)) }
            .filter { $0.count >= min && $0.allSatisfy { $0.isASCII && $0.isLetter } }
    }

    @Test func exactCentreSwipesDecodeToTheWord() {
        var wrong: [String] = []
        let words = letterWords()
        for w in words where dec.decode(points: centreSwipe(w)).candidates.first?.word != w { wrong.append(w) }
        #expect(Double(wrong.count) / Double(words.count) < 0.05, "wrong: \(wrong)")
    }

    @Test func deterministic() {
        var rng = SplitMix64(seed: 3)
        let pts = SwipeSynth.trace("tomorrow", layout: testLayout, profile: .normal, rng: &rng)!
        #expect(dec.decode(points: pts) == dec.decode(points: pts))
    }

    @Test func tapIsNotASwipe() {
        let c = centre("h")
        let r = dec.decode(points: [SwipePoint(c, t: 0), SwipePoint(c, t: 0.05),
                                    SwipePoint(CGPoint(x: c.x + 2, y: c.y), t: 0.1)])
        #expect(!r.isSwipe && r.candidates.isEmpty)
        #expect(!dec.decode(points: []).isSwipe)
    }

    @Test func resultShapeAndConfidence() {
        let r = dec.decode(points: centreSwipe("hello"))
        #expect(r.isSwipe && !r.candidates.isEmpty && r.scoredCount > 0 && !r.truncated)
        #expect(r.confidence > 0 && r.confidence <= 1)
        #expect(r.candidates.count <= SwipeParameters().maxCandidates)
        for i in 1..<max(1, r.candidates.count) { #expect(r.candidates[i - 1].score >= r.candidates[i].score) }
    }

    @Test func candidateEndsMatchThePathEnds() {
        // A swipe from 'h' to 'o' only yields words starting near h and ending near o.
        let r = dec.decode(points: centreSwipe("hello"))
        let start = testLayout.firstKey(.letter("h"))!, end = testLayout.firstKey(.letter("o"))!
        for c in r.candidates {
            let f = testLayout.firstKey(.letter(String(c.word.first!)))!, l = testLayout.firstKey(.letter(String(c.word.last!)))!
            #expect(hypot(Double(f.frame.midX - start.frame.midX) / Double(start.frame.width),
                          Double(f.frame.midY - start.frame.midY) / Double(start.frame.height)) <= 1.0 + 1e-9, "\(c.word)")
            #expect(hypot(Double(l.frame.midX - end.frame.midX) / Double(end.frame.width),
                          Double(l.frame.midY - end.frame.midY) / Double(end.frame.height)) <= 1.0 + 1e-9, "\(c.word)")
        }
    }

    @Test func lmWeightChangesRankingTowardFrequentWords() {
        var p = SwipeParameters()
        p.lmWeight = 0
        let noLM = SwipeDecoder(layout: testLayout, lexicon: lex, model: lm, parameters: p)
        let pts = centreSwipe("the")
        #expect(noLM.decode(points: pts).candidates.first?.word == "the")
        #expect(dec.decode(points: pts).candidates.first?.word == "the")
    }

    @Test func splitAndDuoLayoutsUseTheirOwnKeyGeometry() {
        // Templates come from the layout the decoder is built with, so a wide landscape / Duo inner layout decodes
        // with no decoder change.
        let traits = LayoutTraits(displayClass: .duoInner, orientation: .landscape)
        let layout = LayoutEngine.layout(containerSize: CGSize(width: 900, height: 300), traits: traits, kind: .letters)
        let d = SwipeDecoder(layout: layout, lexicon: lex, model: lm)
        var ok = 0, total = 0
        for w in ["hello", "world", "going", "tomorrow", "the", "and", "you", "with"] where lex.lookup(w) != nil {
            total += 1
            if d.decode(points: centreSwipe(w, layout: layout)).candidates.first?.word == w { ok += 1 }
        }
        #expect(total >= 5 && ok >= total - 1, "\(ok)/\(total)")
        // The phone-geometry decoder on the same wide traces must not beat the matching decoder.
        var rng = SplitMix64(seed: 9)
        var sPhone = SwipeScore(), sDuo = SwipeScore()
        for w in letterWords(min: 4).prefix(60) {
            guard let pts = SwipeSynth.trace(w, layout: layout, profile: .normal, rng: &rng) else { continue }
            sDuo.add(truth: w, result: d.decode(points: pts))
            sPhone.add(truth: w, result: dec.decode(points: pts))
        }
        #expect(sDuo.top1 >= sPhone.top1 && sDuo.total > 30)
    }

    struct FakePersonal: PersonalScoreProvider {
        var boosted: String = ""
        var forgotten: Set<String> = []
        var extra: [String] = []
        func score(word: String, context: [String]) -> PersonalScore? {
            word == boosted || extra.contains(word) ? PersonalScore(probability: 0.2, weight: 0.4) : nil
        }
        func completions(prefix: String, limit: Int) -> [PersonalCompletion] {
            extra.filter { $0.hasPrefix(prefix) }.map { PersonalCompletion(word: $0, weight: 1) }
        }
        func isForgotten(_ w: String) -> Bool { forgotten.contains(w) }
        func isNeverCorrect(_ w: String) -> Bool { false }
    }

    @Test func personalModelBoostsAndForgets() {
        let pts = centreSwipe("hello")
        #expect(dec.decode(points: pts).candidates.first?.word == "hello")
        let f = SwipeDecoder(layout: testLayout, lexicon: lex, model: lm, personal: FakePersonal(forgotten: ["hello"]))
        #expect(!f.decode(points: pts).candidates.map(\.word).contains("hello"))
        let oov = "hellp"
        #expect(lex.lookup(oov) == nil)
        let e = SwipeDecoder(layout: testLayout, lexicon: lex, model: lm, personal: FakePersonal(boosted: "hello", extra: [oov]))
        let r = e.decode(points: centreSwipe(oov))
        #expect(r.candidates.first?.word == oov && r.candidates.first?.wordID == nil && r.candidates.first?.usedPersonal == true)
        let b = e.decode(points: pts)
        #expect(b.candidates.first?.word == "hello" && b.candidates.first?.usedPersonal == true)
    }

    @Test func nodeVisitCapTruncatesAndReports() {
        var p = SwipeParameters()
        p.maxNodeVisits = 5
        let d = SwipeDecoder(layout: testLayout, lexicon: lex, model: lm, parameters: p)
        let r = d.decode(points: centreSwipe("tomorrow"))
        #expect(r.truncated && r.nodesVisited <= 6)
    }
}

@Suite struct SwipeGeometryTests {
    @Test func resampleIsEquidistantAndKeepsEnds() {
        let path = [KP(x: 0, y: 0), KP(x: 4, y: 0), KP(x: 4, y: 3)]
        var r: [KP] = []
        SwipeGeometry.resample(path, count: 8, into: &r)
        #expect(r.count == 8 && r.first! == path[0] && abs(r.last!.x - 4) < 1e-9 && abs(r.last!.y - 3) < 1e-9)
        for i in 1..<r.count { #expect(abs(r[i].dist(r[i - 1]) - 1.0) < 0.42) }   // 7 units / 7 steps, corner cuts chord
        #expect(abs(r[1].x - 1) < 1e-9 && abs(r[4].x - 4) < 1e-9)
    }

    @Test func cornersAndDwellsAreFound() {
        let path = [KP(x: 0, y: 0), KP(x: 4, y: 0), KP(x: 4, y: 4)]
        let c = SwipeGeometry.corners(path, degrees: 55)
        #expect(c.count == 1 && c[0].dist(KP(x: 4, y: 0)) < 0.5)
        #expect(SwipeGeometry.corners([KP(x: 0, y: 0), KP(x: 8, y: 0)], degrees: 55).isEmpty)
        let pts = [KP(x: 0, y: 0), KP(x: 1, y: 0), KP(x: 2, y: 0), KP(x: 2.01, y: 0), KP(x: 2.0, y: 0.01), KP(x: 2.0, y: 0), KP(x: 3, y: 0)]
        let times = [0.0, 0.03, 0.06, 0.09, 0.12, 0.15, 0.18]
        let d = SwipeGeometry.dwells(pts, times: times, speed: 2, minSeconds: 0.06)
        #expect(d.count == 1 && d[0].dist(KP(x: 2, y: 0)) < 0.1)
        #expect(SwipeGeometry.dwells(pts, times: [Double](repeating: 0, count: 7), speed: 2, minSeconds: 0.06).isEmpty)
    }
}
