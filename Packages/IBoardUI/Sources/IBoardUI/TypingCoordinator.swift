import CoreGraphics
import Foundation
import IBoardCore
import IBoardEngine
import IBoardLayout

// Wiring of the engine into the typing path (M2-04 strip wiring + F2/F4 integration). UIKit-free so it is testable
// with `swift test`: the keyboard target feeds it key events and a `TextProxy`, and renders `StripContent`.
//
// Privacy: the current word (and the previous two lowercase words, for LM context) live in memory only while they
// are being typed; they go to the engine request and the personal learner, never to a log, file or signpost.

// MARK: - Seams (so tests can fake the actors)

public protocol SuggestionEngine: Sendable {
    func beginRequest() -> UInt64
    func submit(_ request: EngineRequest) async -> Suggestions?
    func updateLayout(_ layout: KeyboardLayout) async
    /// The personal store changed (a learning batch was applied): take fresh scorer / phrase snapshots.
    func refreshPersonal() async
    /// Apply the learned touch model (F14) for `context`; nil goes back to the base parameters.
    func applyTouchModel(_ model: AdaptiveTouchModel?, context: TouchModelContext?) async
}

extension SuggestionEngine {
    public func refreshPersonal() async {}
    public func applyTouchModel(_ model: AdaptiveTouchModel?, context: TouchModelContext?) async {}
}

/// Binds the engine actor to the seam together with the personal store it refreshes from. The engine's own
/// types (`Suggestions`, `SuggestionSlot`, `EngineRequest`) are used directly.
public struct EngineBridge: SuggestionEngine {
    public let actor: EngineActor
    public let store: PersonalStore?
    public init(_ actor: EngineActor, store: PersonalStore? = nil) {
        self.actor = actor
        self.store = store
    }
    public func beginRequest() -> UInt64 { actor.beginRequest() }
    public func submit(_ request: EngineRequest) async -> Suggestions? { await actor.submit(request) }
    public func updateLayout(_ layout: KeyboardLayout) async { await actor.updateLayout(layout) }
    public func refreshPersonal() async {
        if let store { await actor.refreshPersonal(from: store) }
    }
    public func applyTouchModel(_ model: AdaptiveTouchModel?, context: TouchModelContext?) async {
        await actor.applyTouchModel(model, context: context)
    }
}

public protocol PersonalLearning: Sendable {
    func setIncognito(_ on: Bool) async
    func fieldDidChange(_ traits: FieldTraits) async
    func wordCommitted(_ word: String, source: CommitSource) async
    func typingContinued() async
    func lastWordReopened() async
    func autocorrectReverted(original: String) async
    func sentenceBoundary() async
    func flush() async
}

extension PersonalLearner: PersonalLearning {}

// MARK: - Strip content

/// What the three strip slots show, and what each slot means when tapped.
public struct StripContent: Equatable, Sendable {
    public var texts: [String]
    public var slots: [SuggestionSlot?]
    /// Next-word predictions (no word being typed).
    public var isPrediction: Bool

    public static let empty = StripContent(texts: ["", "", ""], slots: [nil, nil, nil], isPrediction: false)

    public init(texts: [String], slots: [SuggestionSlot?], isPrediction: Bool) {
        self.texts = texts
        self.slots = slots
        self.isPrediction = isPrediction
    }

    /// Typing: engine order `[literal, best, alternative]` is already the display order (best in the middle).
    /// Prediction: the most likely word goes in the middle.
    public init(_ s: Suggestions) {
        let isPrediction = s.literal.isEmpty
        var order = Array(s.slots.prefix(3)).map { Optional($0) }
        while order.count < 3 { order.append(nil) }
        if isPrediction { order = [order[1], order[0], order[2]] }
        self.slots = order
        self.texts = order.map { slot in
            guard let slot else { return "" }
            return slot.showsQuotes ? "\u{201C}\(slot.text)\u{201D}" : slot.text
        }
        self.isPrediction = isPrediction
    }
}

// MARK: - Field configuration

public struct FieldConfig: Sendable, Equatable {
    public var learning: FieldTraits
    public var autocorrect: AutocorrectTraits
    public var punctuation: PunctuationTraits

    public init(learning: FieldTraits = .default, autocorrect: AutocorrectTraits = AutocorrectTraits(),
                punctuation: PunctuationTraits = PunctuationTraits()) {
        self.learning = learning
        self.autocorrect = autocorrect
        self.punctuation = punctuation
    }

    /// No suggestions at all in secure fields.
    public var suggestionsEnabled: Bool { !learning.isSecureTextEntry }
    /// Credentials, contact handles, URLs and number pads are never rewritten.
    public var autocorrectEnabled: Bool { suggestionsEnabled && learning.exclusion == nil }
}

// MARK: - Context words

public enum ContextWords {
    /// The last two completed words before the cursor in the current sentence, lowercase. A trailing partial word
    /// (cursor directly after letters) is not included. Transient: the result is passed to one engine request.
    public static func previous(in context: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let enders: Set<Character> = [".", "!", "?", "\u{2026}", "\u{0964}", "\u{3002}"]
        for ch in context.suffix(300) {
            if ch.isLetter || ch == "'" || ch == "\u{2019}" {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current.lowercased()); current = "" }
                if enders.contains(ch) || ch.isNewline { tokens.removeAll() }
                if ch.isNumber { tokens.removeAll() }
            }
        }
        // A trailing token is the word being typed: dropped.
        return Array(tokens.suffix(2)).map { $0.replacingOccurrences(of: "\u{2019}", with: "'") }
    }
}

/// What the insight counters learn from typing: counts only.
public enum InsightEvent: Sendable, Equatable {
    case word(swiped: Bool)
    case autocorrect(accepted: Bool)
}

// MARK: - Ordered background work

@MainActor
final class OrderedQueue {
    private var tail: Task<Void, Never>?
    func drain() async { await tail?.value }
    func enqueue(_ op: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await op()
        }
    }
}

// MARK: - Coordinator

@MainActor
public final class TypingCoordinator {
    public var onStripChange: ((StripContent) -> Void)?
    /// The coordinator edited the field asynchronously (a decoded swipe was inserted): the host re-evaluates shift.
    public var onAsyncEdit: (() -> Void)?
    /// Whether shift is currently on (capitalises predictions).
    public var shiftActive: () -> Bool = { false }
    public private(set) var content = StripContent.empty
    public private(set) var config = FieldConfig()
    public var autocorrectSettings = AutocorrectSettings()
    /// App setting `autocorrect == .off`: nothing is replaced (not even contractions); suggestions still show.
    public var autocorrectionEnabled = true
    public private(set) var autocorrectState = AutocorrectState()
    public private(set) var incognito = false

    private let input: InputController
    private let now: () -> TimeInterval
    private var engine: (any SuggestionEngine)?
    private var learner: (any PersonalLearning)?
    private let engineQueue = OrderedQueue()
    private let learnerQueue = OrderedQueue()
    private var idleFlush: Task<Void, Never>?

    private var lettersLayout: KeyboardLayout?
    private var letterKey: [String: Int] = [:]
    private var touchPoints: [Int: CGPoint] = [:]

    // The word session (memory only).
    private var word = ""
    private var hits: [KeyHit] = []
    /// Text before an in-word apostrophe ("don’" of "don’t"): the token is learned whole and never autocorrected.
    private var tokenPrefix = ""
    private var prevWords: [String] = []
    private var lastSuggestions: Suggestions?
    private var awaitingContinue = false
    private var lastCommit: (text: String, trailing: String, hits: [KeyHit])?
    private var perfPending: (sequence: UInt64, interval: PerfInterval)?
    private var latestRequest: UInt64 = 0
    private var lastFieldTraits: FieldTraits?
    /// Aggregate typing events for the insight counters (F16). Carries no text. Not sent while incognito or in
    /// excluded fields.
    public var onInsight: ((InsightEvent) -> Void)?
    private var autocorrectPendingAccept = false
    private func emitInsight(_ e: InsightEvent) {
        guard !incognito, config.autocorrectEnabled else { return }
        onInsight?(e)
    }
    private var lastPersonalRefresh: TimeInterval = -.infinity
    /// Minimum time between personal snapshot refreshes triggered by single word commits.
    public var personalRefreshInterval: TimeInterval = 3

    // Adaptive touch model (F14, M2-07 follow-up). Aggregate offsets only, never text.
    private var touchModel = AdaptiveTouchModel()
    private var touchModelStore: AdaptiveTouchFileStore?
    private var touchModelDirty = false
    private var touchModelApplied = 0

    // Swipe typing (M4-03). Memory only.
    private var swipeDecoder: (any SwipeDecoding)?
    private let swipeQueue = OrderedQueue()
    private var swipePending = false
    private var deferredInput: [@MainActor () -> Void] = []
    /// The word the last swipe inserted and the text that followed it (the implied space). Valid until anything else
    /// is typed; it is what whole-word backspace, re-pick and "." after a swipe act on.
    private var lastSwipe: (word: String, trailing: String)?
    /// The strip currently shows the swipe's alternatives.
    private var swipeStripShown = false

    public init(input: InputController, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.input = input
        self.now = now
    }

    // MARK: Wiring

    public func setEngine(_ engine: (any SuggestionEngine)?) {
        self.engine = engine
        if let engine, let l = lettersLayout { engineQueue.enqueue { await engine.updateLayout(l) } }
        pushTouchModel()
        if engine != nil { requestPrediction() } else { setContent(.empty) }
    }

    public func setSwipeDecoder(_ decoder: (any SwipeDecoding)?) {
        swipeDecoder = decoder
        if let decoder, let l = lettersLayout { swipeQueue.enqueue { await decoder.updateLayout(l) } }
        // A swipe made while the engine was still loading is decoded now (if it is recent enough to still be wanted).
        if decoder != nil, let early = earlySwipe {
            earlySwipe = nil
            if now() - early.time <= Self.earlySwipeLifetime { swipeEnded(points: early.points, shift: early.shift) }
        }
    }

    /// The last swipe that ended before the decoder existed (first swipe right after the keyboard appears).
    private var earlySwipe: (points: [SwipePoint], shift: ShiftState, time: TimeInterval)?
    static let earlySwipeLifetime: TimeInterval = 6

    public var hasSwipeDecoder: Bool { swipeDecoder != nil }
    /// A swipe is being decoded (input that arrives meanwhile is replayed after the word is inserted).
    public var isSwipePending: Bool { swipePending }
    /// The word the last swipe inserted, while it is still the last thing in the field.
    public var lastSwipedWord: String? { lastSwipe?.word }

    public func setLearner(_ learner: (any PersonalLearning)?) {
        self.learner = learner
        guard let learner else { return }
        let inc = incognito
        let traits = lastFieldTraits
        learnerQueue.enqueue {
            await learner.setIncognito(inc)
            if let traits { await learner.fieldDidChange(traits) }
        }
    }

    /// Waits until queued engine and learner work has finished (tests).
    public func waitForIdle() async {
        await engineQueue.drain()
        await swipeQueue.drain()
        await learnerQueue.drain()
    }

    public var hasEngine: Bool { engine != nil }
    public var hasLearner: Bool { learner != nil }

    /// Letters layouts only: other layers do not produce engine hits.
    public func setLayout(_ layout: KeyboardLayout) {
        guard layout.kind == .letters else { return }
        guard layout != lettersLayout else { return }
        let oldContext = touchContext
        lettersLayout = layout
        var map: [String: Int] = [:]
        for (i, k) in layout.keys.enumerated() { if case .letter(let s) = k.identity { map[s] = i } }
        letterKey = map
        if let engine { engineQueue.enqueue { await engine.updateLayout(layout) } }
        if let swipeDecoder { swipeQueue.enqueue { await swipeDecoder.updateLayout(layout) } }
        if touchContext != oldContext { pushTouchModel() }
    }

    /// Installs the learned touch model (loaded by the host from extension-local storage). It is applied to the
    /// engine at once, again after every `touchModelApplyEvery` newly learned words, and saved with the idle flush.
    public func setTouchModel(_ model: AdaptiveTouchModel, store: AdaptiveTouchFileStore?) {
        touchModel = model
        touchModelStore = store
        touchModelDirty = false
        pushTouchModel()
    }

    public var learnedTouchSamples: Int {
        guard let ctx = touchContext else { return 0 }
        return touchModel.sampleCount(in: ctx)
    }

    /// Wipes the learned touch model and its file (reset personal data).
    public func resetTouchModel() {
        touchModel.resetAll()
        touchModelStore?.delete()
        touchModelDirty = false
        pushTouchModel()
    }

    private var touchContext: TouchModelContext? {
        lettersLayout.map { TouchModelContext(orientation: $0.traits.orientation, displayClass: $0.traits.displayClass) }
    }

    private func pushTouchModel() {
        guard let engine else { return }
        let model = touchModel, ctx = touchContext
        touchModelApplied = model.sampleCount(in: ctx ?? TouchModelContext(orientation: .portrait, displayClass: .phone))
        engineQueue.enqueue { await engine.applyTouchModel(model, context: ctx) }
    }

    /// Records the touch offsets of a committed, uncorrected word when the engine was sure of it.
    private func recordTouches(word w: String, hits: [KeyHit]) {
        guard !incognito, config.autocorrectEnabled, let layout = lettersLayout, let ctx = touchContext,
              w.count == hits.count, w.count >= 2 else { return }
        // The engine does not expose the literal posterior: "literal is a known word and no better reading was
        // proposed" is the available evidence of a confident decode.
        guard let s = lastSuggestions, s.literal.lowercased() == w.lowercased(), s.autocorrect == nil,
              let first = s.slots.first, first.role == .literal, !first.showsQuotes else { return }
        var samples: [TouchSample] = []
        for (ch, h) in zip(w, hits) {
            guard h.keyIndex < layout.keys.count, let k = letterKey[String(ch).lowercased()] else { return }
            let hitKey = layout.keys[h.keyIndex]
            let point = CGPoint(x: hitKey.frame.midX + h.normalized.x * hitKey.frame.width,
                                y: hitKey.frame.midY + h.normalized.y * hitKey.frame.height)
            samples.append(TouchSample(key: layout.keys[k].identity, point: point, keyFrame: layout.keys[k].frame))
        }
        let before = touchModel.sampleCount(in: ctx)
        let rejection = touchModel.record(CommittedWordTouches(samples: samples, confidence: 0.95), in: ctx)
        guard rejection == nil else { return }
        touchModelDirty = true
        if touchModel.sampleCount(in: ctx) / Self.touchModelApplyEvery > before / Self.touchModelApplyEvery { pushTouchModel() }
    }

    static let touchModelApplyEvery = 20

    private func saveTouchModelIfNeeded() {
        guard touchModelDirty else { return }
        touchModelDirty = false
        if let store = touchModelStore {
            let model = touchModel
            // Tiny file (<= 256 KB); off the main thread.
            Task.detached(priority: .utility) { try? store.save(model) }
        }
        pushTouchModel()
    }

    public func setIncognito(_ on: Bool) {
        guard on != incognito else { return }
        incognito = on
        if let learner { learnerQueue.enqueue { await learner.setIncognito(on) } }
    }

    /// Call when the text field changes (new document or new traits): ends the word session and tells the learner.
    public func fieldDidChange(_ new: FieldConfig) {
        config = new
        resetSession()
        autocorrectState.noteOtherInput()
        lastCommit = nil
        lastSwipe = nil
        swipeStripShown = false
        awaitingContinue = false
        lastFieldTraits = new.learning
        if let learner {
            let traits = new.learning
            learnerQueue.enqueue { await learner.fieldDidChange(traits) }
        }
        prevWords = ContextWords.previous(in: input.proxy.contextBefore ?? "")
        if config.suggestionsEnabled { requestPrediction() } else { setContent(.empty) }
    }

    /// Updates traits without a field change (e.g. a trait flipped in the same field).
    public func updateConfig(_ new: FieldConfig) {
        guard new != config else { return }
        config = new
        if !config.suggestionsEnabled { setContent(.empty) }
    }

    // MARK: Touch hints

    /// The controller reports finger positions so a typed letter can be turned into the `KeyHit` the decoder wants.
    public func trackTouch(id: Int, at point: CGPoint) { touchPoints[id] = point }
    public func releaseTouch(id: Int) { touchPoints[id] = nil }

    private func hit(forLetter letter: String) -> KeyHit? {
        guard let layout = lettersLayout, let k = letterKey[letter.lowercased()] else { return nil }
        for p in touchPoints.values {
            if let h = layout.nearestHit(to: p), h.keyIndex == k { return h }
        }
        // No finger matches (rollover edge case): the key centre.
        let f = layout.keys[k].frame
        return layout.nearestHit(to: CGPoint(x: f.midX, y: f.midY))
    }

    // MARK: Stale proxy context (P-24)

    /// Our own last context-changing edit: the text before the cursor as the proxy reported it before the edit
    /// (`base`) and what it must hold afterwards (`result`). `documentContextBefore` lags our insertions, so a fast
    /// follow-up key that still sees `base` is given `result` instead.
    private var recentEdit: (base: String, result: String, time: TimeInterval)?
    private static let recentEditLifetime: TimeInterval = 1.5
    /// A word was typed right before the pending swipe: the field ends in a letter even if the proxy has not caught up.
    private var swipeFollowsWord = false

    private func currentContext(_ edit: (base: String, result: String, time: TimeInterval)? = nil) -> String? {
        let ctx = input.proxy.contextBefore
        guard let e = edit ?? recentEdit, now() - e.time < Self.recentEditLifetime, (ctx ?? "") == e.base else { return ctx }
        return e.result
    }

    // MARK: Input events

    private static let correctingPunctuation: Set<String> = [".", ",", ";", ":", "!", "?", ")"]
    private static let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]

    /// A key's text output (already cased by shift).
    public func insert(_ text: String) {
        guard !text.isEmpty else { return }
        if deferWhileSwiping({ $0.insert(text) }) { return }
        let swiped = lastSwipe
        let prior = recentEdit
        noteTyped()
        if let swiped, SwipeSpacing.closers.contains(text) {
            // "hello " + "." -> "hello.": take the implied space back.
            let ctx = currentContext(prior)
            if ctx == nil || ctx!.hasSuffix(swiped.word + swiped.trailing) {
                for _ in 0..<swiped.trailing.count { input.proxy.deleteBackwardOnce() }
                autocorrectState.noteOtherInput()
                let left = ctx.map { String($0.dropLast(swiped.trailing.count)) } ?? swiped.word
                insertSeparatorOrSymbol(text, leftContext: left, prior: nil)
                return
            }
        }
        autocorrectState.noteOtherInput()
        if text.count == 1, let c = text.first, c.isLetter, config.suggestionsEnabled, let h = hit(forLetter: text) {
            let interval = Perf.begin(.keystrokeToSuggestions)
            word.append(c)
            hits.append(h)
            input.insert(text)
            requestSuggestions(perf: interval)
            return
        }
        if text == "'" || text == "\u{2019}", !word.isEmpty, tokenPrefix.isEmpty {
            let e = SmartPunctuation.edit(forInserting: text, leftContext: word, traits: config.punctuation)
            input.insert(e.insert)
            tokenPrefix = word + e.insert
            word = ""
            hits = []
            lastSuggestions = nil
            setContent(.empty)
            return
        }
        insertSeparatorOrSymbol(text, prior: prior)
    }

    /// The word being typed right now (empty after a separator or while a swipe is pending). Memory only.
    public var typedToken: String { tokenPrefix + word }

    /// M3-05: the typed token is a Text Replacement shortcut; replaces it with `expansion` plus a space. The shortcut
    /// is not learned or autocorrected; the expansion starts a fresh word context.
    public func expandShortcut(_ expansion: String) {
        if deferWhileSwiping({ $0.expandShortcut(expansion) }) { return }
        let token = typedToken
        guard !token.isEmpty, !expansion.isEmpty else { return }
        noteTyped()
        autocorrectState.noteOtherInput()
        for _ in 0..<token.count { input.proxy.deleteBackwardOnce() }
        input.insert(expansion + " ")
        word = ""
        tokenPrefix = ""
        hits = []
        lastSuggestions = nil
        lastCommit = nil
        setContent(.empty)
        requestPrediction(afterInserting: expansion + " ")
    }

    /// Alternates and other direct insertions: ends the word literally, then inserts.
    public func insertDirect(_ text: String) {
        if deferWhileSwiping({ $0.insertDirect(text) }) { return }
        noteTyped()
        autocorrectState.noteOtherInput()
        endWordLiterally()
        input.insert(text)
    }

    private func insertSeparatorOrSymbol(_ text: String, leftContext: String? = nil,
                                         prior: (base: String, result: String, time: TimeInterval)?) {
        let token = tokenPrefix + word
        let rawBefore = input.proxy.contextBefore ?? ""
        var lc = leftContext ?? currentContext(prior) ?? ""
        if !token.isEmpty, !lc.hasSuffix(token) { lc = token }
        let e = SmartPunctuation.edit(forInserting: text, leftContext: lc, traits: config.punctuation)
        var deleteCount = e.deleteBackward
        var insertText = e.insert
        var committed = token
        var source = CommitSource.typed
        var original: String?
        if !token.isEmpty, tokenPrefix.isEmpty, config.autocorrectEnabled, autocorrectionEnabled,
           text == " " || Self.correctingPunctuation.contains(text),
           let fixed = correction(for: word), fixed != word {
            deleteCount += word.count
            insertText = fixed + e.insert
            committed = fixed
            source = .autocorrected
            original = word
        }
        for _ in 0..<deleteCount { input.proxy.deleteBackwardOnce() }
        input.insert(insertText)
        recentEdit = (rawBefore, String(lc.dropLast(deleteCount)) + insertText, now())

        if let original {
            autocorrectState.recordApplied(original: original, corrected: committed, trailing: e.insert, at: now())
        }
        let endsSentence = e.insert.first.map { Self.terminators.contains($0) } ?? false
        if !token.isEmpty {
            if source == .typed, tokenPrefix.isEmpty { recordTouches(word: token, hits: hits) }
            commit(committed, source: source)
            lastCommit = (committed, e.insert, hits)
            if !endsSentence { prevWords = Array((prevWords + [committed.lowercased()]).suffix(2)) }
        } else {
            lastCommit = nil
        }
        if endsSentence {
            prevWords = []
            enqueueLearner(refresh: .always) { await $0.sentenceBoundary() }
        }
        word = ""
        tokenPrefix = ""
        hits = []
        lastSuggestions = nil
        requestPrediction(afterInserting: String(lc.dropLast(deleteCount)) + insertText)
    }

    /// The word the user typed, while an autocorrection just applied can still be undone by one backspace.
    public var undoableAutocorrection: String? { autocorrectState.lastCorrection?.original }

    /// Reverts the last autocorrection (same as pressing backspace right after it).
    public func undoAutocorrection() {
        guard undoableAutocorrection != nil else { return }
        deleteBackward()
    }

    public func deleteBackward() {
        if deferWhileSwiping({ $0.deleteBackward() }) { return }
        let ctxNow = currentContext()
        recentEdit = nil
        if let swiped = lastSwipe {
            lastSwipe = nil
            swipeStripShown = false
            let ctx = ctxNow
            let text = swiped.word + swiped.trailing
            if ctx == nil || ctx!.hasSuffix(text) {
                // Backspace right after a swipe deletes the whole word (F3).
                noteSwipeWordRemoved()
                for _ in 0..<text.count { input.proxy.deleteBackwardOnce() }
                autocorrectState.noteOtherInput()
                lastCommit = nil
                resetSession()
                requestPrediction(afterInserting: ctx.map { String($0.dropLast(text.count)) })
                return
            }
        }
        // Backspace directly after an autocorrection restores what the user typed.
        if let edit = autocorrectState.backspace(at: now(), settings: autocorrectSettings) {
            for _ in 0..<edit.deleteBackward { input.proxy.deleteBackwardOnce() }
            input.insert(edit.insert)
            let saved = lastCommit?.hits ?? []
            awaitingContinue = false
            lastCommit = nil
            if !prevWords.isEmpty { prevWords.removeLast() }
            tokenPrefix = ""
            word = edit.insert
            hits = saved.count == word.count ? saved : (synthesizedHits(for: word) ?? [])
            if hits.count != word.count { word = ""; hits = [] }
            autocorrectPendingAccept = false
            emitInsight(.autocorrect(accepted: false))
            if let learner {
                let original = edit.insert
                learnerQueue.enqueue { await learner.autocorrectReverted(original: original) }
            }
            requestSuggestions(perf: nil)
            return
        }
        input.deleteBackward()
        if !word.isEmpty {
            word.removeLast()
            if !hits.isEmpty { hits.removeLast() }
            if word.isEmpty { hits = []; lastSuggestions = nil; requestPrediction() } else { requestSuggestions(perf: nil) }
        } else if !tokenPrefix.isEmpty {
            // Deleted the apostrophe: the prefix is the word again.
            let w = String(tokenPrefix.dropLast())
            tokenPrefix = ""
            reopen(w)
        } else if awaitingContinue, let lc = lastCommit, lc.trailing.count == 1 {
            awaitingContinue = false
            lastCommit = nil
            if !prevWords.isEmpty { prevWords.removeLast() }
            if let learner { learnerQueue.enqueue { await learner.lastWordReopened() } }
            reopen(lc.text)
        } else {
            lastCommit = nil
        }
    }

    /// The word is being edited again after a separator was deleted. Hits are rebuilt at the key centres.
    private func reopen(_ w: String) {
        if let h = synthesizedHits(for: w) {
            word = w
            hits = h
            requestSuggestions(perf: nil)
        } else {
            word = ""
            hits = []
            setContent(.empty)
        }
    }

    public func deleteWord() {
        if deferWhileSwiping({ $0.deleteWord() }) { return }
        noteTyped(); autocorrectState.noteOtherInput()
        input.deleteWord()
        if awaitingContinue, lastCommit != nil, let learner { learnerQueue.enqueue { await learner.lastWordReopened() } }
        awaitingContinue = false
        lastCommit = nil
        resetSession()
        scheduleResync()
    }

    /// Backspace swipe-delete release (M5-03): deletes `graphemes` clusters (the planned words) one proxy call each.
    public func deleteRun(graphemes: Int) {
        guard graphemes > 0 else { return }
        if deferWhileSwiping({ $0.deleteRun(graphemes: graphemes) }) { return }
        noteTyped(); autocorrectState.noteOtherInput()
        for _ in 0..<graphemes { input.proxy.deleteBackwardOnce() }
        afterRunDeleted()
    }

    /// The backspace swipe's words were already removed from the host by the in-field preview (`MarkedDeletePreview`);
    /// finish like `deleteRun` without deleting again.
    public func finishPreviewedDelete() {
        if deferWhileSwiping({ $0.finishPreviewedDelete() }) { return }
        noteTyped(); autocorrectState.noteOtherInput()
        afterRunDeleted()
    }

    private func afterRunDeleted() {
        if awaitingContinue, lastCommit != nil, let learner { learnerQueue.enqueue { await learner.lastWordReopened() } }
        awaitingContinue = false
        lastCommit = nil
        resetSession()
        scheduleResync()
    }

    /// Spacebar cursor (M5-02): moves the cursor by grapheme steps / hard-line jumps, converted to the UTF-16 offset
    /// the proxy counts (P-24). Ends the current word session; returns whether the cursor was asked to move.
    @discardableResult
    public func moveCursor(graphemes: Int = 0, lines: Int = 0) -> Bool {
        if deferWhileSwiping({ $0.moveCursor(graphemes: graphemes, lines: lines) }) { return true }
        let before = input.proxy.contextBefore ?? "", after = input.proxy.contextAfter ?? ""
        var offset = 0
        var b = before, a = after
        // Jumps and steps are planned against the context as it will be after the previous part moved.
        for _ in 0..<abs(lines) {
            guard let o = CursorMath.lineJumpOffset(up: lines < 0, before: b, after: a) else { break }
            offset += o
            (b, a) = Self.shifted(before: b, after: a, by: o)
        }
        if graphemes != 0 { offset += CursorMath.utf16Offset(graphemes: graphemes, before: b, after: a, crossingLineEnd: true) }
        guard offset != 0 else { return false }
        input.proxy.adjustPosition(byUTF16: offset)
        noteTyped(); autocorrectState.noteOtherInput()
        awaitingContinue = false
        lastCommit = nil
        resetSession()
        scheduleResync()
        return true
    }

    /// Selection drag (M5-05): the virtual selection already planned the exact UTF-16 offset.
    public func adjustCursor(utf16 offset: Int) {
        guard offset != 0 else { return }
        if deferWhileSwiping({ $0.adjustCursor(utf16: offset) }) { return }
        input.proxy.adjustPosition(byUTF16: offset)
        noteTyped(); autocorrectState.noteOtherInput()
        awaitingContinue = false
        lastCommit = nil
        resetSession()
        scheduleResync()
    }

    /// Carries out the host steps of a selection action (move, delete backwards, insert). The pasteboard part of the
    /// edit belongs to the caller. Inserted text is never learned.
    public func applySelectionEdit(_ edit: SelectionEdit) {
        if deferWhileSwiping({ $0.applySelectionEdit(edit) }) { return }
        noteTyped(); autocorrectState.noteOtherInput()
        endWordLiterally()
        if edit.moveUTF16 != 0 { input.proxy.adjustPosition(byUTF16: edit.moveUTF16) }
        for _ in 0..<edit.deleteGraphemes { input.proxy.deleteBackwardOnce() }
        if let text = edit.insert { input.insert(text) }
        awaitingContinue = false
        lastCommit = nil
        resetSession()
        scheduleResync()
    }

    /// The context split after moving the cursor by `offset` UTF-16 units (offset always lands on a boundary).
    private static func shifted(before: String, after: String, by offset: Int) -> (String, String) {
        let all = Array(before.utf16) + Array(after.utf16)
        let i = max(0, min(all.count, before.utf16.count + offset))
        return (String(decoding: all[..<i], as: UTF16.self), String(decoding: all[i...], as: UTF16.self))
    }

    /// Text before the cursor for the backspace-swipe preview (read per preview change, never stored).
    public var contextBeforeForPreview: String { input.proxy.contextBefore ?? "" }

    /// The strip content last published (the host restores it after a delete preview).
    public var stripContent: StripContent { content }

    /// Returns whether the field accepted the return key.
    @discardableResult
    public func returnKey() -> Bool {
        if deferWhileSwiping({ $0.returnKey() }) { return true }
        let token = tokenPrefix + word
        guard input.returnKey() else { return false }
        noteTyped(); autocorrectState.noteOtherInput()
        if !token.isEmpty { commit(token, source: .typed) }
        enqueueLearner(refresh: .always) { await $0.sentenceBoundary() }
        resetSession()
        lastCommit = nil
        prevWords = []
        requestPrediction(afterInserting: "\n")
        return true
    }

    /// Layer switch, keyboard hidden, anything that makes the word session meaningless.
    public func endWordLiterally() {
        if deferWhileSwiping({ $0.endWordLiterally() }) { return }
        let token = tokenPrefix + word
        if !token.isEmpty {
            commit(token, source: .typed)
            prevWords = Array((prevWords + [token.lowercased()]).suffix(2))
        }
        resetSession()
        lastCommit = nil
    }

    public func keyboardWillDisappear() {
        lastSwipe = nil
        swipeStripShown = false
        endWordLiterally()
        autocorrectState.noteOtherInput()
        flushLearner()
    }

    // MARK: Strip taps

    /// A tap on strip slot `index` (0...2).
    public func tapSlot(_ index: Int) {
        guard index >= 0, index < content.slots.count, let slot = content.slots[index], !slot.text.isEmpty else { return }
        if deferWhileSwiping({ $0.tapSlot(index) }) { return }
        if swipeStripShown, let swiped = lastSwipe {
            scheduleIdleFlush()
            repick(slot.text, replacing: swiped)
            return
        }
        noteTyped()
        autocorrectState.noteOtherInput()
        let typed = word
        let replaces = !typed.isEmpty && tokenPrefix.isEmpty
        guard replaces || word.isEmpty && tokenPrefix.isEmpty else { return }
        var source = CommitSource.suggestionTapped
        if slot.role == .literal {
            source = .typed
            if lastSuggestions?.autocorrect != nil { autocorrectState.userChoseLiteral(typed, settings: autocorrectSettings) }
        }
        for _ in 0..<(replaces ? typed.count : 0) { input.proxy.deleteBackwardOnce() }
        input.insert(slot.text + " ")
        commit(slot.text, source: source)
        prevWords = Array((prevWords + [slot.text.lowercased()]).suffix(2))
        lastCommit = (slot.text, " ", hits)
        word = ""
        hits = []
        lastSuggestions = nil
        requestPrediction(afterInserting: slot.text + " ")
    }

    // MARK: Swipe typing (M4-03)

    /// Runs `op` after the pending swipe is inserted, so keys typed while the decoder works keep their order.
    private func deferWhileSwiping(_ op: @escaping @MainActor (TypingCoordinator) -> Void) -> Bool {
        guard swipePending else { return false }
        deferredInput.append { [unowned self] in op(self) }
        return true
    }

    /// Decodes a swipe path to candidate words (best first) without touching the text field: used where the word goes
    /// somewhere else, like the emoji search field. Empty when the decoder is not loaded yet or nothing matches.
    public func decodeSwipeWords(points: [SwipePoint]) async -> [String] {
        guard points.count >= 2, let decoder = swipeDecoder else { return [] }
        let outcome = await decoder.decode(points: points, previousWords: [])
        return outcome?.words ?? []
    }

    /// The finger lifted after a swipe. The word being typed (if any) is committed as typed, the path is decoded on
    /// the engine's queue, and the best word is inserted with auto-space before and an implied space after.
    /// `shift` is the shift state at lift time. Nothing is inserted when there is no decoder yet or no match.
    public func swipeEnded(points: [SwipePoint], shift: ShiftState) {
        guard config.suggestionsEnabled, points.count >= 2 else { return }
        guard let decoder = swipeDecoder else {
            earlySwipe = (points, shift, now())
            return
        }
        earlySwipe = nil
        if deferWhileSwiping({ $0.swipeEnded(points: points, shift: shift) }) { return }
        let priorEdit = recentEdit
        noteTyped(clearingSwipe: false)
        if !(tokenPrefix + word).isEmpty { swipeFollowsWord = true }
        recentEdit = priorEdit // the proxy may still lag the keys typed before the swipe
        autocorrectState.noteOtherInput()
        endWordLiterally()
        swipePending = true
        let previous = prevWords
        swipeQueue.enqueue { [weak self] in
            let outcome = await decoder.decode(points: points, previousWords: previous)
            await self?.applySwipe(outcome, shift: shift)
        }
    }

    private func applySwipe(_ outcome: SwipeOutcome?, shift: ShiftState) {
        let followsWord = swipeFollowsWord
        swipeFollowsWord = false
        defer {
            swipePending = false
            let ops = deferredInput
            deferredInput = []
            for op in ops { op() }
        }
        guard let outcome, !outcome.words.isEmpty else { return }
        defer { onAsyncEdit?() }
        let words = outcome.words.prefix(3).map { SwipeSpacing.cased($0, shift: shift) }
        let best = words[0]
        // After another swipe the field already ends with the implied space (the proxy may lag a run-loop turn).
        let rawBefore = input.proxy.contextBefore ?? ""
        let before = currentContext()
        let lead = lastSwipe != nil ? "" : ((followsWord || SwipeSpacing.needsSpace(before: before)) ? " " : "")
        input.insert(lead + best + " ")
        recentEdit = (rawBefore, (before ?? "") + lead + best + " ", now())
        autocorrectState.noteOtherInput()
        commit(best, source: .swipe)
        prevWords = Array((prevWords + [best.lowercased()]).suffix(2))
        lastCommit = nil
        lastSwipe = (best, " ")
        word = ""
        hits = []
        lastSuggestions = nil
        // Strip: the best word in the middle, the next two beside it; tapping one replaces the word.
        var order: [SuggestionSlot?] = [nil, nil, nil]
        for (i, w) in words.enumerated() {
            let slot = SuggestionSlot(text: w, role: i == 0 ? .best : .alternative)
            order[i == 0 ? 1 : (i == 1 ? 0 : 2)] = slot
        }
        swipeStripShown = true
        setContent(StripContent(texts: order.map { $0?.text ?? "" }, slots: order, isPrediction: false))
    }

    /// A tap on a swipe alternative: the word just inserted is replaced (F3 re-pick).
    private func repick(_ text: String, replacing swiped: (word: String, trailing: String)) {
        let ctx = currentContext()
        recentEdit = nil
        let old = swiped.word + swiped.trailing
        lastSwipe = nil
        swipeStripShown = false
        guard ctx == nil || ctx!.hasSuffix(old) else { requestPrediction(); return }
        autocorrectState.noteOtherInput()
        if text != swiped.word {
            for _ in 0..<old.count { input.proxy.deleteBackwardOnce() }
            input.insert(text + swiped.trailing)
            noteSwipeWordRemoved()
            commit(text, source: .suggestionTapped)
            prevWords = Array((prevWords + [text.lowercased()]).suffix(2))
        }
        lastSwipe = (text, swiped.trailing)
        let base = ctx.map { String($0.dropLast(old.count)) }
        requestPrediction(afterInserting: base.map { $0 + text + swiped.trailing })
    }

    /// The swiped word was deleted or replaced: it must not be learned as accepted.
    private func noteSwipeWordRemoved() {
        if awaitingContinue {
            awaitingContinue = false
            if let learner { learnerQueue.enqueue { await learner.lastWordReopened() } }
        }
        if !prevWords.isEmpty { prevWords.removeLast() }
    }

    // MARK: Context resync

    /// The host text changed (`textDidChange`): drop the word session when the proxy no longer agrees with it.
    public func resync() {
        if swipePending { return } // the word is about to be inserted; the proxy is not up to date
        let ctx = input.proxy.contextBefore
        // No left context means an empty field (cleared by the host, a submitted search, a new field) or a proxy that
        // has not caught up. Either way any word session we still hold is stale, and without this check the strip
        // stayed empty for good: `requestPrediction` refuses to run while a word is pending.
        if ctx == nil { confirmEmptyContext(); return }
        if let ctx, let swiped = lastSwipe, !ctx.hasSuffix(swiped.word + swiped.trailing) {
            lastSwipe = nil
            swipeStripShown = false
        }
        if let ctx {
            let token = tokenPrefix + word
            if !token.isEmpty, !ctx.hasSuffix(token) { resetSession(); autocorrectState.noteOtherInput() }
            if let lc = lastCommit, !ctx.hasSuffix(lc.text + lc.trailing) { lastCommit = nil; awaitingContinue = false }
        }
        guard word.isEmpty, tokenPrefix.isEmpty, !swipeStripShown, let ctx else { return }
        let words = ContextWords.previous(in: ctx)
        if words != prevWords || content == .empty {
            prevWords = words
            requestPrediction()
        }
    }

    /// Re-checks a nil left context after a beat (the proxy can lag the host by a turn); if it is still nil, everything
    /// the session remembers about earlier text is dropped and the strip asks for a fresh prediction.
    private func confirmEmptyContext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.swipePending, self.input.proxy.contextBefore == nil else { return }
                let stale = !self.word.isEmpty || !self.tokenPrefix.isEmpty || self.lastSwipe != nil || self.lastCommit != nil
                    || self.swipeStripShown || !self.prevWords.isEmpty || self.content == .empty
                guard stale else { return }
                self.resetSession()
                self.lastSwipe = nil
                self.lastCommit = nil
                self.swipeStripShown = false
                self.awaitingContinue = false
                self.prevWords = []
                self.autocorrectState.noteOtherInput()
                self.requestPrediction()
            }
        }
    }

    private var resyncPending = false
    private func scheduleResync() {
        guard !resyncPending else { return }
        resyncPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.resyncPending = false
                self?.resync()
            }
        }
    }

    // MARK: Learner helpers

    private func noteTyped(clearingSwipe: Bool = true) {
        recentEdit = nil
        if clearingSwipe {
            lastSwipe = nil
            swipeStripShown = false
        }
        if awaitingContinue {
            awaitingContinue = false
            if autocorrectPendingAccept {
                autocorrectPendingAccept = false
                emitInsight(.autocorrect(accepted: true)) // the user typed on: the correction stood
            }
            if let learner { learnerQueue.enqueue { await learner.typingContinued() } }
        }
        scheduleIdleFlush()
    }

    private func commit(_ text: String, source: CommitSource) {
        awaitingContinue = true
        autocorrectPendingAccept = source == .autocorrected
        emitInsight(.word(swiped: source == .swipe))
        enqueueLearner(refresh: .throttled) { await $0.wordCommitted(text, source: source) }
    }

    private enum PersonalRefresh { case never, throttled, always }

    /// Runs `op` on the learner in order, then (per `refresh`) hands the engine a fresh personal snapshot so learned
    /// words show up in suggestions. `.throttled` skips the refresh when one ran less than `personalRefreshInterval`
    /// ago; the idle flush always refreshes, so nothing waits long.
    private func enqueueLearner(refresh: PersonalRefresh, _ op: @escaping @Sendable (any PersonalLearning) async -> Void) {
        guard let learner else { return }
        var doRefresh = false
        switch refresh {
        case .never: break
        case .always: doRefresh = true
        case .throttled: doRefresh = now() - lastPersonalRefresh >= personalRefreshInterval
        }
        if doRefresh { lastPersonalRefresh = now() }
        let engine = doRefresh ? engine : nil
        learnerQueue.enqueue {
            await op(learner)
            await engine?.refreshPersonal()
        }
    }

    private func scheduleIdleFlush() {
        idleFlush?.cancel()
        idleFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.flushLearner()
        }
    }

    public func flushLearner() {
        saveTouchModelIfNeeded()
        enqueueLearner(refresh: .always) { await $0.flush() }
    }

    // MARK: Autocorrect

    private func correction(for typed: String) -> String? {
        if typed.dropFirst().contains(where: { $0.isUppercase }) { return nil } // ALL CAPS / camelCase: leave alone
        if let c = SmartPunctuation.contraction(forWord: typed), c.isAutoApplicable { return c.replacement }
        guard let s = lastSuggestions, s.literal.lowercased() == typed.lowercased() else { return nil }
        if case .correct(let to, _) = AutocorrectPolicy.decide(
            literal: typed, proposal: s.autocorrect, traits: config.autocorrect,
            settings: autocorrectSettings, state: autocorrectState) {
            return to
        }
        return nil
    }

    // MARK: Engine requests

    private func requestSuggestions(perf: PerfInterval?) {
        guard let engine, config.suggestionsEnabled, tokenPrefix.isEmpty, !word.isEmpty else {
            perfPending = nil
            if word.isEmpty { requestPrediction() } else { setContent(.empty) }
            return
        }
        let seq = engine.beginRequest()
        latestRequest = seq
        perfPending = perf.map { (seq, $0) }
        let req = EngineRequest(sequence: seq, touches: .hits(hits), previousWords: prevWords,
                                capitalizeFirst: word.first?.isUppercase == true)
        engineQueue.enqueue { [weak self] in
            let s = await engine.submit(req)
            await self?.deliver(s, sequence: seq)
        }
    }

    private func requestPrediction(afterInserting tail: String? = nil) {
        guard let engine, config.suggestionsEnabled, tokenPrefix.isEmpty, word.isEmpty else {
            if !config.suggestionsEnabled || !tokenPrefix.isEmpty { setContent(.empty) }
            return
        }
        let seq = engine.beginRequest()
        latestRequest = seq
        perfPending = nil
        let cap: Bool
        let ctx = tail ?? input.proxy.contextBefore ?? ""
        switch config.punctuation.autocapitalization {
        case .none: cap = false
        default: cap = shiftActive() || SmartPunctuation.shouldAutocapitalize(leftContext: ctx, mode: config.punctuation.autocapitalization)
        }
        let req = EngineRequest(sequence: seq, touches: .hits([]), previousWords: prevWords, capitalizeFirst: cap)
        engineQueue.enqueue { [weak self] in
            let s = await engine.submit(req)
            await self?.deliver(s, sequence: seq)
        }
    }

    private func deliver(_ s: Suggestions?, sequence: UInt64) {
        guard let s, sequence == latestRequest else { return }
        if let p = perfPending, p.sequence == sequence {
            Perf.end(p.interval)
            perfPending = nil
        }
        if s.literal.isEmpty {
            lastSuggestions = nil
        } else {
            guard !word.isEmpty else { return }
            lastSuggestions = s
        }
        setContent(StripContent(s))
    }

    private func setContent(_ c: StripContent) {
        guard c != content else { return }
        content = c
        onStripChange?(c)
    }

    private func resetSession() {
        word = ""
        tokenPrefix = ""
        hits = []
        lastSuggestions = nil
        perfPending = nil
        if engine != nil { latestRequest = engine?.beginRequest() ?? 0 } // invalidates anything in flight
        setContent(.empty)
    }

    private func synthesizedHits(for w: String) -> [KeyHit]? {
        guard let layout = lettersLayout, !w.isEmpty else { return nil }
        var out: [KeyHit] = []
        for ch in w {
            guard let k = letterKey[String(ch).lowercased()],
                  let h = layout.nearestHit(to: CGPoint(x: layout.keys[k].frame.midX, y: layout.keys[k].frame.midY))
            else { return nil }
            out.append(h)
        }
        return out
    }

    // MARK: Auto-capitalisation

    /// Shift state for the text before the cursor (abbreviation-aware).
    public func autoShift(context: String?) -> ShiftState {
        // A proxy that still reports the text from before our last edit would auto-capitalise from stale text.
        let context = recentEdit.flatMap { e in (context ?? "") == e.base ? currentContext() : nil } ?? context
        switch config.punctuation.autocapitalization {
        case .none: return .off
        case .allCharacters: return .capsLock
        case .words, .sentences:
            return SmartPunctuation.shouldAutocapitalize(leftContext: context ?? "", mode: config.punctuation.autocapitalization) ? .once : .off
        }
    }
}
