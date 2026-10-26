import CoreGraphics
import Foundation
import Synchronization
import Testing
import IBoardEngine
import IBoardLayout
@testable import IBoardUI

// MARK: Fakes

private final class FakeProxy: TextProxy {
    var text = ""
    var contextBefore: String? { text }
    var hasText: Bool { !text.isEmpty }
    func insert(_ t: String) { text += t }
    func deleteBackwardOnce() { if !text.isEmpty { text.removeLast() } }
}

private final class FakeEngine: SuggestionEngine {
    private let counter = Mutex<UInt64>(0)
    let handler: @Sendable (EngineRequest) -> EngineResult?
    let requests = Mutex<[EngineRequest]>([])
    init(_ handler: @escaping @Sendable (EngineRequest) -> EngineResult?) { self.handler = handler }
    func beginRequest() -> UInt64 { counter.withLock { $0 += 1; return $0 } }
    func submit(_ r: EngineRequest) async -> EngineResult? {
        requests.withLock { $0.append(r) }
        guard counter.withLock({ $0 }) == r.sequence else { return nil }
        return handler(r)
    }
    func updateLayout(_ layout: KeyboardLayout) async {}
}

private enum Event: Equatable, Sendable {
    case incognito(Bool), field, committed(String, CommitSource), continued, reopened, reverted(String), sentence, flush
}

private final class FakeLearner: PersonalLearning {
    let events = Mutex<[Event]>([])
    func add(_ e: Event) { events.withLock { $0.append(e) } }
    var log: [Event] { events.withLock { $0 } }
    func setIncognito(_ on: Bool) async { add(.incognito(on)) }
    func fieldDidChange(_ traits: FieldTraits) async { add(.field) }
    func wordCommitted(_ word: String, source: CommitSource) async { add(.committed(word, source)) }
    func typingContinued() async { add(.continued) }
    func lastWordReopened() async { add(.reopened) }
    func autocorrectReverted(original: String) async { add(.reverted(original)) }
    func sentenceBoundary() async { add(.sentence) }
    func flush() async { add(.flush) }
}

private func slot(_ t: String, _ role: SuggestionSlot.Role, quotes: Bool = false) -> StripSlot {
    StripSlot(text: t, role: role, showsQuotes: quotes)
}

/// Engine that proposes "the" for "teh" with high confidence and nothing else.
private func tehEngine() -> FakeEngine {
    FakeEngine { r in
        guard case .hits(let h) = r.touches, !h.isEmpty else {
            return EngineResult(sequence: r.sequence, literal: "", slots: [slot("i", .best), slot("the", .alternative)])
        }
        if h.count == 3 {
            return EngineResult(sequence: r.sequence, literal: "teh",
                               slots: [slot("teh", .literal, quotes: true), slot("the", .best), slot("ten", .alternative)],
                               autocorrect: AutocorrectProposal(word: "the", confidence: 0.999, literalIsWord: false))
        }
        return EngineResult(sequence: r.sequence, literal: String(repeating: "x", count: h.count),
                           slots: [slot("x", .literal)])
    }
}

private final class Clock { var t: TimeInterval = 100 }

@MainActor
private struct Rig {
    let proxy = FakeProxy()
    let coordinator: TypingCoordinator
    let layout: KeyboardLayout
    let engine: FakeEngine
    let learner = FakeLearner()
    let clock = Clock()

    init(engine: FakeEngine = tehEngine(), config: FieldConfig = FieldConfig()) {
        layout = LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters)
        self.engine = engine
        let box = clock
        coordinator = TypingCoordinator(input: InputController(proxy: proxy), now: { box.t })
        coordinator.setLayout(layout)
        coordinator.fieldDidChange(config)
        coordinator.setEngine(engine)
        coordinator.setLearner(learner)
    }

    func type(_ s: String) async {
        for ch in s {
            let str = String(ch)
            if let k = layout.firstKey(.letter(str.lowercased())) {
                let p = CGPoint(x: k.frame.midX, y: k.frame.midY)
                coordinator.trackTouch(id: 1, at: p)
                coordinator.insert(str)
                coordinator.releaseTouch(id: 1)
            } else {
                coordinator.insert(str)
            }
            await coordinator.waitForIdle()
        }
    }
    func backspace() async { coordinator.deleteBackward(); await coordinator.waitForIdle() }
}

// MARK: Tests

@MainActor
@Suite("TypingCoordinator")
struct TypingCoordinatorTests {
    @Test func stripShowsLiteralBestAlternative() async {
        let r = Rig()
        await r.type("teh")
        #expect(r.coordinator.content.texts == ["\u{201C}teh\u{201D}", "the", "ten"])
    }

    @Test func predictionPutsBestInMiddle() async {
        let r = Rig()
        await r.coordinator.waitForIdle()
        #expect(r.coordinator.content.texts == ["the", "i", ""])
        #expect(r.coordinator.content.isPrediction)
    }

    @Test func autocorrectOnSpaceAndBackspaceRestores() async {
        let r = Rig()
        await r.type("teh ")
        #expect(r.proxy.text == "the ")
        await r.backspace()
        #expect(r.proxy.text == "teh")
        // The session continues with the original word: the strip offers it again.
        #expect(r.coordinator.content.texts[1] == "the")
        let log = r.learner.log
        #expect(log.contains(.committed("the", .autocorrected)))
        #expect(log.contains(.reverted("teh")))
    }

    @Test func restoreOnlyDirectlyAfterCorrection() async {
        let r = Rig()
        await r.type("teh a")
        #expect(r.proxy.text == "the a")
        await r.backspace()
        #expect(r.proxy.text == "the ")
    }

    @Test func restoreExpiresAfterWindow() async {
        let r = Rig()
        await r.type("teh ")
        r.clock.t += 31
        await r.backspace()
        #expect(r.proxy.text == "the")
    }

    @Test func punctuationCommitsWithCorrection() async {
        let r = Rig()
        await r.type("teh,")
        #expect(r.proxy.text == "the,")
    }

    @Test func secondRestoreMakesWordNeverCorrect() async {
        let r = Rig()
        for _ in 0..<2 {
            await r.type("teh ")
            await r.backspace()
            for _ in 0..<3 { await r.backspace() }
        }
        await r.type("teh ")
        #expect(r.proxy.text == "teh ")
    }

    @Test func noAutocorrectWhenDisabledByTraits() async {
        var c = FieldConfig()
        c.autocorrect = AutocorrectTraits(autocorrection: .no)
        let r = Rig(config: c)
        await r.type("teh ")
        #expect(r.proxy.text == "teh ")
    }

    @Test func noAutocorrectInExcludedFieldButSuggestionsStay() async {
        let c = FieldConfig(learning: FieldTraits(keyboardType: .emailAddress))
        let r = Rig(config: c)
        await r.type("teh ")
        #expect(r.proxy.text == "teh ")
        #expect(r.coordinator.config.suggestionsEnabled)
    }

    @Test func secureFieldHasNoSuggestionsAndNoRequests() async {
        let c = FieldConfig(learning: FieldTraits(isSecureTextEntry: true))
        let r = Rig(config: c)
        await r.type("teh ")
        #expect(r.proxy.text == "teh ")
        #expect(r.coordinator.content == .empty)
        #expect(r.engine.requests.withLock { $0.isEmpty })
    }

    @Test func contractionAppliedWithoutEngine() async {
        let r = Rig(engine: FakeEngine { _ in nil })
        await r.type("dont ")
        #expect(r.proxy.text == "don't ")
    }

    @Test func apostropheKeepsTokenTogether() async {
        let r = Rig()
        await r.type("don'")
        await r.type("t ")
        #expect(r.proxy.text == "don\u{2019}t ")
        #expect(r.learner.log.contains(.committed("don\u{2019}t", .typed)))
    }

    @Test func doubleSpaceBecomesPeriod() async {
        let r = Rig()
        await r.type("hello")
        r.coordinator.insert(" ")
        r.coordinator.insert(" ")
        #expect(r.proxy.text == "hello. ")
        await r.coordinator.waitForIdle()
        #expect(r.learner.log.contains(.sentence))
    }

    @Test func smartQuotes() async {
        let r = Rig()
        r.coordinator.insert("\"")
        await r.type("hi")
        r.coordinator.insert("\"")
        #expect(r.proxy.text == "\u{201C}hi\u{201D}")
    }

    @Test func learnerEventOrder() async {
        let r = Rig()
        await r.type("hello world")
        r.coordinator.insert(".")
        await r.coordinator.waitForIdle()
        let log = r.learner.log
        #expect(log.first == .incognito(false))
        #expect(log.contains(.committed("hello", .typed)))
        #expect(log.contains(.continued))
        #expect(log.last == .sentence)
        let ci = log.firstIndex(of: .committed("hello", .typed))!
        let ki = log.firstIndex(of: .continued)!
        #expect(ci < ki)
    }

    @Test func backspaceIntoCommittedWordReopens() async {
        let r = Rig(engine: FakeEngine { _ in nil })
        await r.type("hello ")
        await r.backspace()
        #expect(r.proxy.text == "hello")
        #expect(r.learner.log.contains(.reopened))
        let before = r.learner.log.filter { $0 == .continued }.count
        await r.type("s")
        #expect(r.learner.log.filter { $0 == .continued }.count == before)
    }

    @Test func returnEndsSentence() async {
        let r = Rig()
        await r.type("hello")
        #expect(r.coordinator.returnKey())
        await r.coordinator.waitForIdle()
        #expect(r.learner.log.suffix(2) == [.committed("hello", .typed), .sentence])
    }

    @Test func incognitoIsForwarded() async {
        let r = Rig()
        r.coordinator.setIncognito(true)
        await r.coordinator.waitForIdle()
        #expect(r.learner.log.contains(.incognito(true)))
    }

    @Test func tapSlotReplacesWordAndAddsSpace() async {
        let r = Rig()
        await r.type("teh")
        r.coordinator.tapSlot(1)
        #expect(r.proxy.text == "the ")
        await r.coordinator.waitForIdle()
        #expect(r.learner.log.contains(.committed("the", .suggestionTapped)))
    }

    @Test func tappingLiteralCountsAsRestoreSignal() async {
        let r = Rig()
        for _ in 0..<2 {
            await r.type("teh")
            r.coordinator.tapSlot(0)
            for _ in 0..<4 { await r.backspace() }
        }
        #expect(r.coordinator.autocorrectState.neverCorrect.contains("teh"))
    }

    @Test func fieldChangeResetsSession() async {
        let r = Rig()
        await r.type("te")
        r.proxy.text = ""
        r.coordinator.fieldDidChange(FieldConfig())
        await r.type("h ")
        #expect(r.proxy.text == "h ")
    }

    @Test func resyncDropsWordWhenCursorMoved() async {
        let r = Rig()
        await r.type("teh")
        r.proxy.text = "something else"
        r.coordinator.resync()
        await r.type(" ")
        #expect(r.proxy.text == "something else ")
    }

    @Test func contextWords() {
        #expect(ContextWords.previous(in: "Hello there. How are ") == ["how", "are"])
        #expect(ContextWords.previous(in: "Hello how ar") == ["hello", "how"])
        #expect(ContextWords.previous(in: "") == [])
        #expect(ContextWords.previous(in: "I can\u{2019}t ") == ["i", "can't"])
    }

    @Test func autoShift() {
        let r = Rig()
        #expect(r.coordinator.autoShift(context: "") == .once)
        #expect(r.coordinator.autoShift(context: "Hello. ") == .once)
        #expect(r.coordinator.autoShift(context: "Hello") == .off)
        #expect(r.coordinator.autoShift(context: "Dr. ") == .off)
    }

    @Test func newerRequestSupersedesOlder() async {
        let r = Rig()
        await r.type("teh")
        r.coordinator.insert("x")
        await r.coordinator.waitForIdle()
        #expect(r.coordinator.content.texts == ["x", "", ""])
    }
}

// MARK: Real engine (small synthetic fixture shipped with the engine package tests)

private func fixtureURL(_ file: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("IBoardEngine/Tests/IBoardEngineTests/Fixtures/small/\(file)")
}

@MainActor
@Suite("TypingCoordinator with EngineActor")
struct TypingCoordinatorRealEngineTests {
    @Test func typesWordAndGetsSuggestions() async throws {
        let layout = LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters)
        let lex = try Lexicon(url: fixtureURL("lexicon.iblex"))
        let lm = try NGramModel(url: fixtureURL("lm.iblm"), lexicon: lex)
        let engine = EngineActor(layout: layout, lexicon: lex, model: lm)
        let proxy = FakeProxy()
        let c = TypingCoordinator(input: InputController(proxy: proxy))
        c.setLayout(layout)
        c.setEngine(EngineBridge(engine))
        c.fieldDidChange(FieldConfig())
        for ch in "hon" {
            let k = layout.firstKey(.letter(String(ch)))!
            c.trackTouch(id: 1, at: CGPoint(x: k.frame.midX, y: k.frame.midY))
            c.insert(String(ch))
            c.releaseTouch(id: 1)
            await c.waitForIdle()
        }
        #expect(proxy.text == "hon")
        #expect(c.content.texts.contains("honest"))
        #expect(!c.content.isPrediction)
    }
}
