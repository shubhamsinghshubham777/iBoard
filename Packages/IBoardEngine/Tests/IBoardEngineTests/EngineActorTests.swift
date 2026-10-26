import CoreGraphics
import Foundation
import Testing
import IBoardEngine
import IBoardLayout

@Suite struct SuggestionsPublicInitTests {
    @Test func constructibleFromOutsideTheModule() {
        let slot = SuggestionSlot(text: "the", role: .best)
        #expect(!slot.showsQuotes && slot.wordID == nil && !slot.isCompletion)
        let s = Suggestions(sequence: 7, literal: "teh", slots: [slot],
                            autocorrect: AutocorrectProposal(word: "the", confidence: 0.99, literalIsWord: false))
        #expect(s.sequence == 7 && s.slots == [slot] && s.phrase == nil)
        #expect(Suggestions.empty(sequence: 3).slots.isEmpty)
    }
}

@Suite struct EngineActorTests {
    let lex: Lexicon
    let lm: NGramModel
    let engine: EngineActor

    init() throws {
        lex = try Fixture.small.lexicon()
        lm = try Fixture.small.model(lexicon: lex)
        engine = EngineActor(layout: testLayout, lexicon: lex, model: lm)
    }

    @Test func typingProducesLiteralBestAlternativeSlots() async throws {
        let seq = engine.beginRequest()
        let s = try #require(await engine.submit(EngineRequest(sequence: seq, touches: .points("th".map(centre)))))
        #expect(s.sequence == seq)
        #expect(s.literal == "th")
        #expect(s.slots.count <= 3)
        #expect(s.slots.first?.role == .literal)
        #expect(s.slots.count == 3 && s.slots[1].role == .best && s.slots[2].role == .alternative)
        #expect(s.phrase == nil)
        #expect(s.slots.dropFirst().allSatisfy { $0.isCompletion })
        #expect(s.autocorrect == nil)
    }

    @Test func typoYieldsProposalAndQuotedLiteral() async throws {
        let k = try #require(testLayout.firstKey(.letter("k")))
        let l = try #require(testLayout.firstKey(.letter("l")))
        var pts = "hello".map(centre)
        pts[3] = CGPoint(x: k.frame.midX * 0.7 + l.frame.midX * 0.3, y: k.frame.midY)
        let s = try #require(await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points(pts))))
        #expect(s.literal == "helko")
        #expect(s.slots[0].text == "helko" && s.slots[0].showsQuotes)
        #expect(s.slots[1].text == "hello")
        #expect(s.autocorrect?.word == "hello")
        #expect((s.autocorrect?.confidence ?? 0) > 0.9)
        #expect(s.autocorrect?.literalIsWord == false)
    }

    @Test func validWordLiteralHasNoQuotes() async throws {
        let s = try #require(await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points("hello".map(centre)))))
        #expect(s.slots[0].text == "hello" && !s.slots[0].showsQuotes)
        #expect(s.autocorrect == nil)
    }

    @Test func capitalizeFirstAppliesToEverySlot() async throws {
        let s = try #require(await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points("th".map(centre)), capitalizeFirst: true)))
        #expect(s.slots.allSatisfy { $0.text.first?.isUppercase == true })
    }

    @Test func emptyTouchesPredictNextWords() async throws {
        let s = try #require(await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points([]), previousWords: ["i"])))
        #expect(s.literal.isEmpty)
        #expect(s.slots.count == 3)
        #expect(s.slots.first?.role == .best)
        #expect(!s.slots.contains { $0.role == .literal })
    }

    @Test func staleRequestIsDropped() async throws {
        let old = engine.beginRequest()
        let new = engine.beginRequest()
        #expect(old != new)
        #expect(await engine.submit(EngineRequest(sequence: old, touches: .points("the".map(centre)))) == nil)
        #expect(await engine.submit(EngineRequest(sequence: new, touches: .points("the".map(centre)))) != nil)
    }

    @Test func invalidatePendingDropsEverythingInFlight() async {
        let seq = engine.beginRequest()
        engine.invalidatePending()
        #expect(await engine.submit(EngineRequest(sequence: seq, touches: .points("the".map(centre)))) == nil)
    }

    @Test func burstOfConcurrentRequestsOnlyDeliversTheNewest() async {
        let e = engine
        var requests: [EngineRequest] = []
        for _ in 0..<40 { requests.append(EngineRequest(sequence: e.beginRequest(), touches: .points("tomorrow".map(centre)))) }
        let newest = requests.last!.sequence
        let results = await withTaskGroup(of: Suggestions?.self) { group in
            for r in requests { group.addTask { await e.submit(r) } }
            var out: [Suggestions] = []
            for await s in group { if let s { out.append(s) } }
            return out
        }
        #expect(results.map(\.sequence) == [newest])
    }

    @Test func requestSupersededWhileQueuedIsDropped() async {
        // Start many requests in order; each later beginRequest() invalidates the one before even though the
        // earlier tasks were already queued behind the actor.
        let e = engine
        let first = EngineRequest(sequence: e.beginRequest(), touches: .points("hello".map(centre)))
        async let a = e.submit(first)
        let second = EngineRequest(sequence: e.beginRequest(), touches: .points("hello".map(centre)))
        let b = await e.submit(second)
        #expect(b?.sequence == second.sequence)
        #expect(await a == nil)
    }

    @Test func layoutUpdateKeepsDecodingWorking() async throws {
        let wide = LayoutEngine.layout(containerSize: CGSize(width: 500, height: 260), traits: LayoutTraits(), kind: .letters)
        await engine.updateLayout(wide)
        let pts = "hello".map { ch -> CGPoint in
            let k = wide.firstKey(.letter(String(ch)))!
            return CGPoint(x: k.frame.midX, y: k.frame.midY)
        }
        let s = try #require(await engine.submit(EngineRequest(sequence: engine.beginRequest(), touches: .points(pts))))
        #expect(s.literal == "hello")
    }
}
