import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

/// Contractions: the apostrophe is not a swipe key, so the trie search passes through it at zero cost.
@Suite struct SwipeContractionTests {
    static let words = ["i'll", "didn't", "shouldn't", "don't", "can't", "it's", "we're", "i'm", "isn't", "that's",
                        "you're", "they're", "wouldn't", "i've", "let's", "he's", "what's", "doesn't", "won't"]

    @Test func lexiconCarriesContractionsWithSensibleFrequency() throws {
        guard let (en, _) = realEnglish() else { return }
        for w in Self.words {
            let id = try #require(en.lookup(w), "missing \(w)")
            #expect(en.logProbability(of: id) > -14, "\(w) too rare")
        }
    }

    @Test func centreSwipesReachContractions() throws {
        guard let (en, lm) = realEnglish() else { return }
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: lm)
        var wrong: [String] = []
        for w in Self.words {
            let r = dec.decode(points: centreSwipe(w.replacingOccurrences(of: "'", with: "")))
            if !r.candidates.prefix(3).contains(where: { $0.word == w }) { wrong.append(w) }
            #expect(!r.truncated)
        }
        #expect(wrong.count <= 1, "not in top-3: \(wrong)")
    }

    @Test func nearlyUnambiguousContractionsWinTop1() throws {
        guard let (en, lm) = realEnglish() else { return }
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: lm)
        for w in ["didn't", "shouldn't", "don't", "can't", "wouldn't", "isn't", "doesn't"] {
            let r = dec.decode(points: centreSwipe(w.replacingOccurrences(of: "'", with: "")))
            #expect(r.candidates.first?.word == w, "\(w) -> \(r.candidates.first?.word ?? "-")")
        }
    }

    @Test func surfaceFormKeepsTheApostropheAndNoDuplicates() throws {
        guard let (en, lm) = realEnglish() else { return }
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: lm)
        let r = dec.decode(points: centreSwipe("didnt"))
        #expect(r.candidates.contains { $0.word == "didn't" })
        #expect(Set(r.candidates.map(\.word)).count == r.candidates.count)
    }

    @Test func noisySyntheticHitRate() throws {
        guard let (en, lm) = realEnglish() else { return }
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: lm)
        var rng = SplitMix64(seed: 11)
        var n = 0, top1 = 0, top3 = 0
        for w in Self.words { for _ in 0..<10 {
            guard let pts = SwipeSynth.trace(w, layout: testLayout, profile: .normal, rng: &rng) else { continue }
            let r = dec.decode(points: pts).candidates.map(\.word)
            n += 1; if r.first == w { top1 += 1 }; if r.prefix(3).contains(w) { top3 += 1 }
        } }
        print("CONTRACTIONS> normal synthetic n=\(n) top1=\(Double(top1) / Double(n) * 100) top3=\(Double(top3) / Double(n) * 100)")
        #expect(Double(top3) / Double(n) > 0.7)
    }
}
