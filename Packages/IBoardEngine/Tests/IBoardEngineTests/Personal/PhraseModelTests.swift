import Foundation
import Testing
@testable import IBoardEngine

private struct FixedLM: PhraseBaseLanguageModel {
    var logP: Double?
    func logProbability(word: String, context: [String]) -> Double? { logP }
}

private func typeSentence(_ words: [String], into store: PersonalStore, times: Int = 1) async {
    for _ in 0..<times {
        for (i, w) in words.enumerated() {
            await store.learn(word: w, context: Array(words[max(0, i - 2)..<i]), increment: 1,
                              phraseContext: Array(words[max(0, i - 5)..<i]))
        }
    }
}

private func makeStore(clock: ManualPersonalClock = ManualPersonalClock()) -> PersonalStore {
    PersonalStore(storage: InMemoryPersonalStorage(), clock: clock)
}

@Suite struct PhraseModelTests {
    @Test func repeatedSentenceBecomesPhraseChip() async throws {
        let store = makeStore()
        await typeSentence(["see", "you", "at", "the", "airport"], into: store, times: 3)
        let s = await store.phraseSuggester()
        let p = try #require(s.suggest(context: ["see"]))
        #expect(p.words == ["you", "at", "the", "airport"])
        #expect(p.confidence >= 0.99)
        #expect(p.uses == 3)
        #expect(p.slot.role == .phrase)
        #expect(p.slot.text == "you at the airport")
    }

    @Test func tapInsertsAllLongPressOnlyNextWord() async throws {
        let store = makeStore()
        await typeSentence(["on", "my", "way", "home"], into: store, times: 2)
        let p = try #require(await store.phraseSuggester().suggest(context: ["on"]))
        #expect(p.semantics == .standard)
        #expect(p.semantics.tap == .insertAllWords && p.semantics.longPress == .insertNextWordOnly)
        #expect(p.text(for: p.semantics.tap) == "my way home")
        #expect(p.text(for: p.semantics.longPress) == "my")
    }

    @Test func singleObservationIsNotAPhrase() async {
        let store = makeStore()
        await typeSentence(["see", "you", "at", "the", "airport"], into: store)
        #expect(await store.phraseSuggester().suggest(context: ["see"]) == nil)
    }

    @Test func ambiguousContinuationsStayBelowThreshold() async {
        let store = makeStore()
        await typeSentence(["see", "you", "at", "the"], into: store, times: 3)
        await typeSentence(["see", "you", "later", "today"], into: store, times: 3)
        // after "see" the table splits 50/50 (confidence 0.5 < 0.6)
        #expect(await store.phraseSuggester().suggest(context: ["see"]) == nil)
        // a lower threshold accepts it
        var c = PhraseConfig(); c.confidenceThreshold = 0.4
        #expect(await store.phraseSuggester(config: c).suggest(context: ["see"]) != nil)
    }

    @Test func singleWordContinuationIsNotAPhraseChip() async {
        let store = makeStore()
        await typeSentence(["at", "the", "airport"], into: store, times: 3)
        #expect(await store.phraseSuggester().suggest(context: ["at", "the"]) == nil)
        #expect(await store.phraseSuggester().suggest(context: ["at"]) != nil)
    }

    @Test func partialWordMustMatchFirstContinuationWord() async {
        let store = makeStore()
        await typeSentence(["on", "my", "way", "home"], into: store, times: 2)
        let s = await store.phraseSuggester()
        #expect(s.suggest(context: ["on"], currentPrefix: "m")?.words.first == "my")
        #expect(s.suggest(context: ["on"], currentPrefix: "x") == nil)
    }

    @Test func forgottenWordRemovesPhrase() async {
        let store = makeStore()
        await typeSentence(["on", "my", "way", "home"], into: store, times: 3)
        await store.forget("way")
        #expect(await store.phraseSuggester().suggest(context: ["on"]) == nil)
    }

    @Test func decayedPhraseDisappears() async {
        let clock = ManualPersonalClock()
        let store = makeStore(clock: clock)
        await typeSentence(["on", "my", "way", "home"], into: store, times: 2)
        #expect(await store.phraseSuggester().suggest(context: ["on"]) != nil)
        clock.advance(days: 200)
        #expect(await store.phraseSuggester().suggest(context: ["on"]) == nil)
    }

    @Test func baseLMAgreementAdjustsConfidence() async throws {
        let store = makeStore()
        await typeSentence(["on", "my", "way", "home"], into: store, times: 2)
        let agree = try #require(await store.phraseSuggester(baseLM: FixedLM(logP: log(0.5))).suggest(context: ["on"]))
        let disagree = try #require(await store.phraseSuggester(baseLM: FixedLM(logP: log(1e-7))).suggest(context: ["on"]))
        #expect(agree.confidence > disagree.confidence)
        #expect(abs(agree.confidence - 1) < 1e-9)
        #expect(disagree.confidence >= 0.85 - 1e-9 && disagree.confidence < 0.86)
        var strict = PhraseConfig(); strict.confidenceThreshold = 0.9
        #expect(await store.phraseSuggester(config: strict, baseLM: FixedLM(logP: log(1e-7))).suggest(context: ["on"]) == nil)
    }

    @Test func casingIsRestoredFromSurfaces() async throws {
        let store = makeStore()
        for _ in 0..<2 {
            await store.learn(word: "call", increment: 1)
            await store.learn(word: "shubham", surface: "Shubham", context: ["call"], increment: 1, phraseContext: ["call"])
            await store.learn(word: "tomorrow", context: ["call", "shubham"], increment: 1, phraseContext: ["call", "shubham"])
        }
        let p = try #require(await store.phraseSuggester().suggest(context: ["call"]))
        #expect(p.words == ["Shubham", "tomorrow"])
    }

    @Test func emptyContextAndEmptyModelGiveNothing() async {
        let store = makeStore()
        #expect(await store.phraseSuggester().suggest(context: []) == nil)
        #expect(await store.phraseSuggester().isEmpty)
    }
}
