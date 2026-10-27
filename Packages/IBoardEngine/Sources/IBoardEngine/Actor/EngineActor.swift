import CoreGraphics
import Foundation
import IBoardLayout
import Synchronization

/// Touches of the word being typed.
public enum EngineTouches: Sendable {
    /// Resolved by the layout (`KeyboardLayout.hit`), the keyboard's native form.
    case hits([KeyHit])
    /// Raw points in the layout's container coordinates.
    case points([CGPoint])

    var isEmpty: Bool {
        switch self {
        case .hits(let h): return h.isEmpty
        case .points(let p): return p.isEmpty
        }
    }
}

public struct EngineRequest: Sendable {
    /// From `EngineActor.beginRequest()`.
    public var sequence: UInt64
    public var touches: EngineTouches
    /// Words before the current one, oldest first, lowercase NFC; only the last two are used.
    /// Typed text is never stored: this value lives for one request.
    public var previousWords: [String]
    /// Capitalise the first letter of every slot (shift / auto-cap active).
    public var capitalizeFirst: Bool

    public init(sequence: UInt64, touches: EngineTouches, previousWords: [String] = [], capitalizeFirst: Bool = false) {
        self.sequence = sequence
        self.touches = touches
        self.previousWords = previousWords
        self.capitalizeFirst = capitalizeFirst
    }
}

/// Serial background owner of the lexicon, language model and tap decoder (M2-04).
///
/// Code-switching (M7-02): pass a `secondary` language (the Hinglish lexicon and LM) and both lexicons are searched.
/// The previous words set a language log-odds (plus the personal model's EN vs Hinglish lean), which becomes a
/// log-prior added to every candidate's score; a valid secondary-lexicon word is never auto-corrected into a
/// primary-only word (M7-03). Without `secondary` nothing changes.
///
/// Cancellation: `beginRequest()` is callable from any thread (the main actor, per keystroke) and returns a new
/// sequence number that also marks every older one stale. `submit` drops (returns nil) a request that is stale
/// when it starts, and again when it finishes, so the UI never applies out-of-date suggestions. The decode itself
/// is short and is not interrupted mid-way.
public actor EngineActor {
    private let lexicon: Lexicon
    private let model: NGramModel?
    private let secondary: SecondaryLanguage?
    private let codeSwitch: CodeSwitchParameters
    /// The personal model's EN vs Hinglish lean in nats (0 without a secondary language or personal model).
    private var personalBias = 0.0
    /// Effective parameters (base + learned touch model); `baseParameters` is what the caller supplied.
    private var parameters: TapDecoderParameters
    private let baseParameters: TapDecoderParameters
    private var touchModel: (any TouchSpatialModelProvider)?
    private var touchContext: TouchModelContext?
    private var layout: KeyboardLayout
    private var decoder: TapDecoder
    private var personal: (any PersonalScoreProvider)?
    private var phrases: PhraseSuggester?
    private nonisolated let latest = Mutex<UInt64>(0)

    public init(layout: KeyboardLayout, lexicon: Lexicon, model: NGramModel? = nil,
                parameters: TapDecoderParameters = TapDecoderParameters(),
                personal: (any PersonalScoreProvider)? = nil, phrases: PhraseSuggester? = nil,
                secondary: SecondaryLanguage? = nil, codeSwitch: CodeSwitchParameters = CodeSwitchParameters()) {
        self.secondary = secondary
        self.codeSwitch = codeSwitch
        self.personal = personal
        if let personal, let secondary {
            personalBias = CodeSwitch.personalBias(from: personal, primary: lexicon, secondary: secondary, parameters: codeSwitch)
        }
        self.phrases = phrases
        self.layout = layout
        self.lexicon = lexicon
        self.model = model
        self.parameters = parameters
        self.baseParameters = parameters
        self.decoder = TapDecoder(layout: layout, lexicon: lexicon, model: model, parameters: parameters,
                                  secondary: secondary, codeSwitch: codeSwitch)
    }

    /// Registers a new request and invalidates all earlier ones.
    public nonisolated func beginRequest() -> UInt64 {
        latest.withLock { $0 &+= 1; return $0 }
    }

    /// Invalidates everything in flight without starting a request (field change, cursor jump).
    public nonisolated func invalidatePending() { _ = beginRequest() }

    /// The newest sequence number handed out.
    public nonisolated var latestSequence: UInt64 { latest.withLock { $0 } }

    private nonisolated func isStale(_ s: UInt64) -> Bool { latest.withLock { $0 } != s }

    /// Rebuilds the decoder for a new layout (rotation, resize, layer change). `KeyHit`s in later requests must
    /// come from this layout.
    public func updateLayout(_ layout: KeyboardLayout) {
        self.layout = layout
        rebuildDecoder()
    }

    /// Applies the learned touch model (F14) to the decoder: the provider's per-key models for `context` (orientation x
    /// display class of the current layout) override the matching entries of the base `keyModels`, and the decoder is
    /// rebuilt. Pass nil to go back to the base parameters. Call again after the model learned more or the
    /// orientation changed; a rebuild is cheap (letters only), but do it per committed word at most, not per keystroke.
    /// Returns the number of keys that received a learned model.
    @discardableResult
    public func applyTouchModel(_ provider: (any TouchSpatialModelProvider)?, context: TouchModelContext?) -> Int {
        touchModel = provider
        touchContext = context
        return rebuildDecoder()
    }

    /// Re-derives the effective parameters from the base ones plus the touch model and rebuilds the decoder.
    @discardableResult
    private func rebuildDecoder() -> Int {
        var p = baseParameters
        var applied = 0
        if let provider = touchModel, let ctx = touchContext {
            let learned = provider.keyModels(for: ctx)
            for (k, m) in learned { p.keyModels[k] = m }
            applied = learned.count
        }
        parameters = p
        decoder = TapDecoder(layout: layout, lexicon: lexicon, model: model, parameters: p,
                             secondary: secondary, codeSwitch: codeSwitch)
        return applied
    }

    /// Installs (or, with nil, removes) the personal model snapshot. Snapshots are immutable: call again after the
    /// personal store changed (for example after a learning batch) to pick up new words. Typed text is never kept.
    public func setPersonal(scorer: (any PersonalScoreProvider)?, phrases: PhraseSuggester? = nil) {
        personal = scorer
        self.phrases = phrases
        if let scorer, let secondary {
            personalBias = CodeSwitch.personalBias(from: scorer, primary: lexicon, secondary: secondary, parameters: codeSwitch)
        } else {
            personalBias = 0
        }
    }

    /// The personal model's current EN vs Hinglish lean in nats (positive = Hinglish); for diagnostics and tests.
    public var personalLanguageBias: Double { personalBias }

    /// Convenience: takes fresh scorer and phrase-suggester snapshots from `store` (the phrase confidence also uses
    /// the base n-gram model when there is one).
    public func refreshPersonal(from store: PersonalStore, phraseConfig: PhraseConfig = PhraseConfig()) async {
        let base: (any PhraseBaseLanguageModel)? = model.map { NGramPhraseBaseLM(lexicon: lexicon, model: $0) }
        let s = await store.scorer()
        let p = await store.phraseSuggester(config: phraseConfig, baseLM: base)
        setPersonal(scorer: s, phrases: p)
    }

    /// Computes the strip for the request, or nil when it was superseded.
    public func submit(_ request: EngineRequest) -> Suggestions? {
        if isStale(request.sequence) { return nil }
        let ctx = context(for: request.previousWords)
        let out = request.touches.isEmpty ? predict(request, ctx) : typing(request, ctx)
        return isStale(request.sequence) ? nil : out
    }

    /// N-gram contexts (one per lexicon) and the language log-odds for one request.
    private struct Ctx {
        var primary: LMContext
        var secondary: SecondaryContext
    }

    private func context(for words: [String]) -> Ctx {
        if let secondary {
            let c = CodeSwitch.context(previousWords: words, primary: lexicon, secondary: secondary,
                                       parameters: codeSwitch, personalBias: personalBias)
            return Ctx(primary: c.primary, secondary: c.secondary)
        }
        let ids = words.suffix(2).map { lexicon.lookup($0) }
        switch ids.count {
        case 2: return Ctx(primary: LMContext(older: ids[0], recent: ids[1]), secondary: .neutral)
        case 1: return Ctx(primary: LMContext(recent: ids[0]), secondary: .neutral)
        default: return Ctx(primary: .none, secondary: .neutral)
        }
    }

    /// Language log-prior (already scaled by `priorWeight`) of a side; 0 without a secondary language.
    private func prior(_ side: LexiconSide, _ ctx: Ctx) -> Double {
        secondary == nil ? 0 : codeSwitch.priorWeight * ctx.secondary.logPrior(side)
    }

    /// Prior for a word that is in no lexicon: charges no language (the more likely side's prior).
    private func looseLanguagePrior(_ ctx: Ctx) -> Double {
        secondary == nil ? 0 : max(prior(.primary, ctx), prior(.secondary, ctx))
    }

    /// Id and side of `word` in the primary lexicon, else in the secondary one.
    private func lookup(_ word: String) -> (id: Lexicon.WordID, side: LexiconSide)? {
        if let id = lexicon.lookup(word) { return (id, .primary) }
        if let s = secondary, let id = s.lexicon.lookup(word) { return (id, .secondary) }
        return nil
    }

    private func text(_ id: Lexicon.WordID, _ side: LexiconSide) -> String {
        side == .primary ? lexicon.word(of: id) : secondary!.lexicon.word(of: id)
    }

    private nonisolated static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    private func baseLog(_ id: Lexicon.WordID?, _ side: LexiconSide, _ ctx: Ctx) -> Double {
        guard let id else { return parameters.oovLogProbability }
        if side == .secondary, let s = secondary { return s.logProbability(id, ctx.secondary.lm) }
        return model?.logProbability(id, context: ctx.primary) ?? lexicon.logProbability(of: id)
    }

    /// M7-03: the best same-length reading is a primary-only word while the literal is a valid secondary word.
    private func isProtected(literal: String, top: TapCandidate) -> Bool {
        guard let s = secondary, codeSwitch.protectSecondaryWords, top.side == .primary, top.wordID != nil else { return false }
        return CodeSwitch.isProtected(literal: literal, target: top.word, secondary: s)
    }

    /// Folds the personal model into a decode result: learned words and n-grams re-weight the language-model term of
    /// every candidate, forgotten words disappear, personal completions of the typed prefix are added, and the
    /// autocorrect decision is recomputed over the same-length readings.
    private func blend(_ res: TapDecodeResult, previous: [String], ctx: Ctx,
                       with p: any PersonalScoreProvider) -> (TapDecodeResult, literalKnown: Bool) {
        let lw = parameters.lmWeight
        var cands: [TapCandidate] = []
        for var c in res.candidates {
            if !c.isLiteral, p.isForgotten(c.word) { continue }
            if let s = p.score(word: c.word, context: previous) {
                let b = baseLog(c.wordID, c.side, ctx)
                c.score += lw * (PersonalInterpolation.mix(baseLogProb: b, personal: s) - b)
            }
            cands.append(c)
        }
        let literalKnown = res.candidates.first { $0.isLiteral }.map { c in
            c.wordID != nil || p.score(word: c.word, context: previous) != nil } ?? false
        if let lit = res.candidates.first(where: { $0.isLiteral }) {
            // Spatial log-likelihood of the literal, reused for completions of the typed prefix.
            let spatial = lit.score - lw * (PersonalInterpolation.mix(baseLogProb: baseLog(lit.wordID, lit.side, ctx),
                                             personal: p.score(word: lit.word, context: previous)) + lit.languagePrior)
            var have = Set(cands.map { $0.word.lowercased() })
            for pc in p.completions(prefix: res.literal, limit: 3) {
                let low = pc.word.lowercased()
                guard low.count > res.literal.count, have.insert(low).inserted,
                      let s = p.score(word: low, context: previous) else { continue }
                let hit = lookup(low)
                let side = hit?.side ?? .primary
                let b = baseLog(hit?.id, side, ctx)
                let pr = hit == nil ? looseLanguagePrior(ctx) : prior(side, ctx)
                cands.append(TapCandidate(word: hit.map { text($0.id, $0.side) } ?? pc.word, wordID: hit?.id,
                                          score: spatial + lw * (PersonalInterpolation.mix(baseLogProb: b, personal: s) + pr)
                                              - parameters.completionPenalty,
                                          isCompletion: true, isLiteral: false, side: side, languagePrior: pr))
            }
        }
        cands.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.isCompletion != $1.isCompletion { return !$0.isCompletion }
            if ($0.wordID ?? .max) != ($1.wordID ?? .max) { return ($0.wordID ?? .max) < ($1.wordID ?? .max) }
            return $0.side < $1.side
        }
        if cands.count > parameters.maxCandidates {
            let literalCandidate = cands.first { $0.isLiteral }
            cands.removeLast(cands.count - parameters.maxCandidates)
            if let literalCandidate, !cands.contains(where: { $0.isLiteral }) { cands[cands.count - 1] = literalCandidate }
        }
        // Same-length posterior again.
        let same = cands.filter { !$0.isCompletion }
        var autocorrect: TapCandidate?
        var confidence = 0.0
        var literalPosterior = 0.0
        var protected = false
        if let top = same.first {
            let z = same.reduce(0.0) { $0 + exp($1.score - top.score) }
            literalPosterior = same.first { $0.isLiteral }.map { exp($0.score - top.score) / z } ?? 0
            if !top.isLiteral, !p.isNeverCorrect(res.literal) {
                if isProtected(literal: res.literal, top: top) { protected = true } else { autocorrect = top; confidence = 1 / z }
            }
        }
        return (TapDecodeResult(literal: res.literal, candidates: cands, autocorrect: autocorrect,
                                autocorrectConfidence: confidence, literalPosterior: literalPosterior,
                                literalProtected: protected), literalKnown)
    }

    private func typing(_ r: EngineRequest, _ ctx: Ctx) -> Suggestions {
        var res: TapDecodeResult
        switch r.touches {
        case .hits(let h): res = decoder.decode(hits: h, layout: layout, context: ctx.primary, secondaryContext: ctx.secondary)
        case .points(let p): res = decoder.decode(points: p, context: ctx.primary, secondaryContext: ctx.secondary)
        }
        var personalLiteral = false
        if let p = personal {
            (res, personalLiteral) = blend(res, previous: r.previousWords, ctx: ctx, with: p)
        }
        let up = r.capitalizeFirst
        let cap = { (s: String) -> String in up ? Self.capitalized(s) : s }
        let literalCandidate = res.candidates.first { $0.isLiteral }
        let literalIsWord = literalCandidate?.wordID != nil || personalLiteral
        var seen: Set<String> = [res.literal]
        let others = res.candidates.filter { !$0.isLiteral && seen.insert($0.word).inserted }
        let showQuotes = !literalIsWord || res.autocorrect != nil
        var slots = [SuggestionSlot(text: cap(res.literal), role: .literal, showsQuotes: showQuotes,
                                    wordID: literalCandidate?.wordID, isCompletion: false,
                                    side: literalCandidate?.side ?? .primary)]
        for (i, c) in others.prefix(2).enumerated() {
            slots.append(SuggestionSlot(text: cap(c.word), role: i == 0 ? .best : .alternative, showsQuotes: false,
                                        wordID: c.wordID, isCompletion: c.isCompletion, side: c.side))
        }
        let proposal = res.autocorrect.map {
            AutocorrectProposal(word: cap($0.word), confidence: res.autocorrectConfidence, literalIsWord: literalIsWord)
        }
        let phrase = phrases?.suggest(context: r.previousWords, currentPrefix: res.literal)?.slot
        return Suggestions(sequence: r.sequence, literal: res.literal, slots: slots, phrase: phrase, autocorrect: proposal)
    }

    /// Next-word prediction (no touches): the most likely words under the context. Unigram candidates re-ranked
    /// by the n-gram model, then by the personal model (learned words, personal bigram successors).
    private func predict(_ r: EngineRequest, _ ctx: Ctx) -> Suggestions {
        let up = r.capitalizeFirst
        let cap = { (s: String) -> String in up ? Self.capitalized(s) : s }
        var seen: [String: Int] = [:]
        var ranked: [(text: String, id: Lexicon.WordID?, side: LexiconSide, lp: Double)] = []
        func add(_ text: String, _ id: Lexicon.WordID?, _ side: LexiconSide, _ lp: Double) {
            if let i = seen[text] {
                if lp > ranked[i].lp { ranked[i] = (text, id, side, lp) }
                return
            }
            seen[text] = ranked.count
            ranked.append((text, id, side, lp))
        }
        var sources: [(LexiconSide, Lexicon)] = [(.primary, lexicon)]
        if let secondary { sources.append((.secondary, secondary.lexicon)) }
        for (side, lex) in sources {
            for id in lex.completions(prefix: "", limit: 64) {
                let w = lex.word(of: id)
                var lp = baseLog(id, side, ctx) + prior(side, ctx)
                if let p = personal {
                    if p.isForgotten(w) { continue }
                    lp = PersonalInterpolation.mix(baseLogProb: lp, personal: p.score(word: w, context: r.previousWords))
                }
                add(w, id, side, lp)
            }
        }
        if let p = personal {
            var extra = p.completions(prefix: "", limit: 12)
            if let last = r.previousWords.last { extra += p.successors(after: last, limit: 12) }
            for pc in extra {
                let low = pc.word.lowercased()
                guard seen[low] == nil, !p.isForgotten(low),
                      let s = p.score(word: low, context: r.previousWords) else { continue }
                let hit = lookup(low)
                let side = hit?.side ?? .primary
                let base = baseLog(hit?.id, side, ctx) + (hit == nil ? looseLanguagePrior(ctx) : prior(side, ctx))
                add(hit.map { text($0.id, $0.side) } ?? pc.word, hit?.id, side,
                    PersonalInterpolation.mix(baseLogProb: base, personal: s))
            }
        }
        ranked.sort {
            if $0.lp != $1.lp { return $0.lp > $1.lp }
            if $0.id != $1.id { return ($0.id ?? .max) < ($1.id ?? .max) }
            if $0.side != $1.side { return $0.side < $1.side }
            return $0.text < $1.text
        }
        let slots = ranked.prefix(3).enumerated().map { i, e in
            SuggestionSlot(text: cap(e.text), role: i == 0 ? .best : .alternative,
                           showsQuotes: false, wordID: e.id, isCompletion: false, side: e.side)
        }
        let phrase = phrases?.suggest(context: r.previousWords)?.slot
        return Suggestions(sequence: r.sequence, literal: "", slots: slots, phrase: phrase, autocorrect: nil)
    }
}
