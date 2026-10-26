import Foundation

/// What a tap and a long-press on the smart wide chip insert (D-13). Kept as data so the UI, tests and the controller
/// agree: tap inserts the whole continuation, long-press only the next word.
public struct PhraseChipSemantics: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case insertAllWords, insertNextWordOnly }
    public var tap: Action
    public var longPress: Action
    public static let standard = PhraseChipSemantics(tap: .insertAllWords, longPress: .insertNextWordOnly)
}

/// A confident multi-word continuation.
public struct PhraseSuggestion: Sendable, Equatable {
    /// Continuation words in display casing, 2...maxWords of them. Does not include the typed context or prefix.
    public var words: [String]
    /// 0...1: P(continuation | context) estimated from personal lifetime counts, mildly adjusted by the base LM.
    public var confidence: Double
    /// Lifetime observations of the phrase.
    public var uses: Int
    public var semantics: PhraseChipSemantics

    /// Text a tap inserts (words joined by single spaces; the caller adds the leading space if the context needs one).
    public var tapText: String { words.joined(separator: " ") }
    /// Text a long-press inserts: only the next word.
    public var longPressText: String { words.first ?? "" }

    public func text(for action: PhraseChipSemantics.Action) -> String {
        action == .insertAllWords ? tapText : longPressText
    }

    /// The strip slot for `Suggestions.phrase` (role `.phrase`).
    public var slot: SuggestionSlot {
        SuggestionSlot(text: tapText, role: .phrase, showsQuotes: false, wordID: nil, isCompletion: true)
    }
}

/// Base language model evidence for the continuation words (optional).
public protocol PhraseBaseLanguageModel: Sendable {
    /// ln P(word | context), context oldest first (last two used). nil when the base model does not know the word.
    func logProbability(word: String, context: [String]) -> Double?
}

/// Adapter over the engine's base n-gram model.
public struct NGramPhraseBaseLM: PhraseBaseLanguageModel {
    public let lexicon: Lexicon
    public let model: NGramModel
    public init(lexicon: Lexicon, model: NGramModel) { self.lexicon = lexicon; self.model = model }

    public func logProbability(word: String, context: [String]) -> Double? {
        guard let id = lexicon.lookup(word) else { return nil }
        let ids = context.suffix(2).map { lexicon.lookup($0) }
        let ctx = LMContext(older: ids.count == 2 ? ids[0] : nil, recent: ids.last ?? nil)
        return model.logProbability(id, context: ctx)
    }
}

public struct PhraseConfig: Sendable, Equatable {
    /// Minimum final confidence for a phrase chip (untuned placeholder; NOT evaluated on real typing data).
    public var confidenceThreshold = 0.6
    /// A phrase must have been observed at least this often (lifetime).
    public var minUses = 2
    /// ...and still weigh at least this much after decay.
    public var minEffectiveWeight = 1.0
    /// Maximum words in a suggested continuation.
    public var maxWords = 4
    /// Share of the base LM agreement in the final confidence (0 disables the base LM).
    public var baseInfluence = 0.15
    /// Base probability treated as full agreement for one word.
    public var baseReferenceProbability = 0.05
    public init() {}
}

/// Builds a phrase chip from the personal phrase table. Immutable snapshot, `Sendable`, no I/O.
///
/// Context: the words already typed in the current sentence (oldest first, last 5 used) plus an optional partially
/// typed word `currentPrefix` (the first continuation word must start with it). A phrase `c1..ck n1..nm` (3-6 words in
/// the table) matches when the last k context words equal `c1..ck`. Confidence = uses(phrase) / uses(c1..ck), where the
/// denominator comes from the unigram / bigram / trigram / phrase tables (all count one per observation); a missing
/// denominator (pruned) gives the phrase itself as the denominator. Among the phrases above the threshold the
/// longest continuation wins, then the higher confidence. Forgotten words never appear.
public struct PhraseSuggester: Sendable {
    private struct Candidate: Sendable {
        var words: [String]      // normalized, full phrase
        var uses: Int
        var weight: Double
    }

    private let state: PersonalModelState
    public let config: PhraseConfig
    private let baseLM: (any PhraseBaseLanguageModel)?
    private let byFirstWord: [String: [Candidate]]

    public init(state: PersonalModelState, asOf now: Double, config: PhraseConfig = PhraseConfig(),
                baseLM: (any PhraseBaseLanguageModel)? = nil) {
        self.state = state
        self.config = config
        self.baseLM = baseLM
        var index: [String: [Candidate]] = [:]
        for (key, e) in state.phrases {
            let words = key.split(separator: PersonalModelState.separator, omittingEmptySubsequences: false).map(String.init)
            guard (3...6).contains(words.count), Int(e.uses) >= config.minUses else { continue }
            let w = state.effective(e, at: now)
            guard w >= config.minEffectiveWeight else { continue }
            if words.contains(where: { state.forgotten[$0] != nil }) { continue }
            index[words[0], default: []].append(Candidate(words: words, uses: Int(e.uses), weight: w))
        }
        byFirstWord = index
    }

    public var isEmpty: Bool { byFirstWord.isEmpty }

    /// The best confident phrase continuation, or nil.
    public func suggest(context: [String], currentPrefix: String = "") -> PhraseSuggestion? {
        let ctx = context.suffix(5).map(PersonalStore.normalize)
        guard !ctx.isEmpty else { return nil }
        let prefix = PersonalStore.normalize(currentPrefix)
        var best: PhraseSuggestion?
        var bestKey: (Int, Double) = (0, 0)
        for k in 1...ctx.count {
            let tail = Array(ctx.suffix(k))
            guard let cands = byFirstWord[tail[0]] else { continue }
            let denom = prefixUses(tail)
            for c in cands where c.words.count > k && Array(c.words.prefix(k)) == tail {
                let cont = Array(c.words.dropFirst(k))
                guard cont.count >= 2 else { continue }
                if !prefix.isEmpty, !cont[0].hasPrefix(prefix) { continue }
                if cont.contains(where: { state.forgotten[$0] != nil }) { continue }
                let shown = Array(cont.prefix(config.maxWords))
                let personal = min(1, Double(c.uses) / Double(max(denom, c.uses)))
                let conf = adjusted(personal, words: shown, context: tail)
                guard conf >= config.confidenceThreshold else { continue }
                let key = (shown.count, conf)
                if best == nil || key.0 > bestKey.0 || (key.0 == bestKey.0 && key.1 > bestKey.1) {
                    bestKey = key
                    best = PhraseSuggestion(words: shown.map { state.surfaces[$0] ?? $0 }, confidence: conf,
                                            uses: c.uses, semantics: .standard)
                }
            }
        }
        return best
    }

    private func prefixUses(_ tail: [String]) -> Int {
        let kind: PersonalNGramKind
        switch tail.count {
        case 1: kind = .unigram
        case 2: kind = .bigram
        case 3: kind = .trigram
        default: kind = .phrase
        }
        return Int(state.entry(kind, PersonalModelState.key(tail))?.uses ?? 0)
    }

    private func adjusted(_ personal: Double, words: [String], context: [String]) -> Double {
        guard let lm = baseLM, config.baseInfluence > 0 else { return personal }
        var ctx = context
        var total = 0.0
        for w in words {
            if let lp = lm.logProbability(word: w, context: ctx) {
                total += min(1, exp(lp) / config.baseReferenceProbability)
            } else {
                total += 0.5   // unknown to the base model (names, slang): neutral
            }
            ctx.append(w)
        }
        let agreement = total / Double(words.count)
        return personal * ((1 - config.baseInfluence) + config.baseInfluence * agreement)
    }
}

extension PersonalStore {
    /// An immutable phrase suggester as of now.
    public func phraseSuggester(config: PhraseConfig = PhraseConfig(),
                                baseLM: (any PhraseBaseLanguageModel)? = nil) -> PhraseSuggester {
        PhraseSuggester(state: exportState(), asOf: currentTime, config: config, baseLM: baseLM)
    }
}
