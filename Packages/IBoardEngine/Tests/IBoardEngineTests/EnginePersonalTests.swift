import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

@Suite struct EnginePersonalTests {
    let lex: Lexicon
    let lm: NGramModel

    init() throws {
        lex = try Fixture.small.lexicon()
        lm = try Fixture.small.model(lexicon: lex)
    }

    private func engine() -> EngineActor { EngineActor(layout: testLayout, lexicon: lex, model: lm) }
    private func store() -> PersonalStore { PersonalStore(storage: InMemoryPersonalStorage(), clock: ManualPersonalClock()) }

    private func submit(_ e: EngineActor, _ typed: String, previous: [String] = []) async -> Suggestions? {
        await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points(typed.map(centre)), previousWords: previous))
    }

    @Test func learnedOutOfVocabularyWordIsNotQuotedOrCorrected() async throws {
        let name = "zorblax"
        #expect(lex.lookup(name) == nil)
        let e = engine()
        let before = try #require(await submit(e, name))
        #expect(before.slots[0].showsQuotes)
        let st = store()
        for _ in 0..<6 { await st.learn(word: name, increment: 1) }
        await e.refreshPersonal(from: st)
        let after = try #require(await submit(e, name))
        #expect(!after.slots[0].showsQuotes)
        #expect(after.autocorrect == nil)
    }

    @Test func personalCompletionOfLearnedWordAppears() async throws {
        let e = engine()
        let st = store()
        for _ in 0..<8 { await st.learn(word: "zorblax", increment: 1) }
        await e.refreshPersonal(from: st)
        let s = try #require(await submit(e, "zor"))
        #expect(s.slots.contains { $0.text == "zorblax" && $0.isCompletion })
    }

    @Test func forgottenWordDisappearsFromSuggestions() async throws {
        let e = engine()
        let plain = try #require(await submit(e, "th"))
        let victim = try #require(plain.slots.dropFirst().first?.text)
        let st = store()
        await st.learn(word: "unrelated", increment: 1)
        await st.forget(victim)
        await e.refreshPersonal(from: st)
        let after = try #require(await submit(e, "th"))
        #expect(!after.slots.contains { $0.text == victim })
    }

    @Test func personalBigramsDrivePrediction() async throws {
        let e = engine()
        let st = store()
        for _ in 0..<10 {
            await st.learn(word: "see", increment: 50)
            await st.learn(word: "zorblax", context: ["see"], increment: 50)
        }
        await e.refreshPersonal(from: st)
        let s = try #require(await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points([]), previousWords: ["see"])))
        #expect(s.slots.contains { $0.text == "zorblax" })
        let e2 = engine()
        let plain = try #require(await e2.submit(EngineRequest(sequence: e2.beginRequest(), touches: .points([]), previousWords: ["see"])))
        #expect(!plain.slots.contains { $0.text == "zorblax" })
        // Without the previous word the learned word is far less specific but must not crash.
        _ = await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points([])))
    }

    @Test func phraseChipIsFilledAndClearedWhenPersonalIsRemoved() async throws {
        let e = engine()
        let st = store()
        let words = ["see", "you", "at", "the", "airport"]
        for _ in 0..<3 {
            for (i, w) in words.enumerated() {
                await st.learn(word: w, context: Array(words[max(0, i - 2)..<i]), increment: 1,
                               phraseContext: Array(words[max(0, i - 5)..<i]))
            }
        }
        await e.refreshPersonal(from: st)
        let s = try #require(await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points([]), previousWords: ["see"])))
        #expect(s.phrase?.text == "you at the airport" && s.phrase?.role == .phrase)
        await e.setPersonal(scorer: nil)
        let t = try #require(await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points([]), previousWords: ["see"])))
        #expect(t.phrase == nil)
    }

    @Test func noPersonalModelBehavesAsBefore() async throws {
        let e = engine()
        let a = try #require(await submit(e, "hello"))
        await e.setPersonal(scorer: PersonalStore(storage: InMemoryPersonalStorage(), clock: ManualPersonalClock()).scorer())
        let b = try #require(await submit(e, "hello"))
        #expect(a.slots.map(\.text) == b.slots.map(\.text))
    }
}
