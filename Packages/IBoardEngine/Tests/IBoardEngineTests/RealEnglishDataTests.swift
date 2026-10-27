import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine

/// Real English artifacts (Data/english) with the real Hinglish ones as the secondary language, as the keyboard
/// bundles them. Skipped silently when the checkout does not have the data.
func realEnglish() -> (Lexicon, NGramModel)? {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    let dir = url.appendingPathComponent("Data/english")
    guard let lex = try? Lexicon(url: dir.appendingPathComponent("lexicon.iblex")),
          let lm = try? NGramModel(url: dir.appendingPathComponent("lm.iblm"), lexicon: lex) else { return nil }
    return (lex, lm)
}

@Suite struct RealEnglishDataTests {
    @Test func successorsComeFromTheModel() throws {
        guard let (lex, lm) = realEnglish() else { return }
        let the = try #require(lex.lookup("the"))
        let next = lm.successors(after: the, limit: 10).map { lex.word(of: $0) }
        #expect(next.count == 10)
        #expect(Set(next).isDisjoint(with: ["ki", "aur"]))
        #expect(lm.successors(after: the, older: lex.lookup("of"), limit: 5).count == 5)
    }

    @Test func predictionAfterTheIsEnglishEvenWithHinglishLoaded() async throws {
        guard let (lex, lm) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let engine = EngineActor(layout: testLayout, lexicon: lex, model: lm, secondary: SecondaryLanguage(lexicon: hi, model: hiLM))
        let s = try #require(await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points([]), previousWords: ["the"])))
        let words = s.slots.map(\.text)
        print("PREDICT after 'the': \(words)")
        #expect(words.allSatisfy { lex.lookup($0) != nil && hi.lookup($0) == nil || lex.lookup($0) != nil }, "\(words)")
        #expect(!words.contains("ki") && !words.contains("aur"), "\(words)")
    }

    @Test func predictionAfterAHinglishWordStaysHinglish() async throws {
        guard let (lex, lm) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let engine = EngineActor(layout: testLayout, lexicon: lex, model: lm, secondary: SecondaryLanguage(lexicon: hi, model: hiLM))
        let s = try #require(await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points([]), previousWords: ["pata", "nahi"])))
        print("PREDICT after 'pata nahi': \(s.slots.map(\.text))")
        #expect(s.slots.contains { hi.lookup($0.text) != nil && lex.lookup($0.text) == nil }, "\(s.slots.map(\.text))")
    }

    @Test func tehIsCorrectedToTheWithRealData() async throws {
        guard let (lex, lm) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let engine = EngineActor(layout: testLayout, lexicon: lex, model: lm, secondary: SecondaryLanguage(lexicon: hi, model: hiLM))
        let s = try #require(await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points("teh".map(centre)))))
        #expect(s.autocorrect?.word == "the", "\(s.slots.map(\.text)) \(String(describing: s.autocorrect))")
    }
}
