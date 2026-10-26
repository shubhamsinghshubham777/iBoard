import Foundation

/// One tappable chip of the suggestion strip.
public struct SuggestionSlot: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// The exact string under the fingers. Always offered while a word is being typed (D-12).
        case literal
        /// The most likely reading / prediction.
        case best
        case alternative
        /// Reserved for the smart wide phrase chip (D-13, M3-03). Never produced by the M2 engine.
        case phrase
    }

    public var text: String
    public var role: Role
    /// UI hint: show the text in quotes (a literal that is not the engine's best reading).
    public var showsQuotes: Bool
    public var wordID: Lexicon.WordID?
    /// True for a prediction longer than what was typed.
    public var isCompletion: Bool
}

/// The engine's autocorrect proposal; `AutocorrectPolicy` decides whether to apply it.
public struct AutocorrectProposal: Sendable, Equatable {
    public var word: String
    /// Posterior of `word` among the same-length readings (TapDecodeResult.autocorrectConfidence).
    public var confidence: Double
    /// True when the typed literal is itself a lexicon word (stricter policy applies).
    public var literalIsWord: Bool

    public init(word: String, confidence: Double, literalIsWord: Bool) {
        self.word = word
        self.confidence = confidence
        self.literalIsWord = literalIsWord
    }
}

/// Result of one engine request.
public struct Suggestions: Sendable, Equatable {
    /// Sequence number of the request that produced this value.
    public var sequence: UInt64
    /// Nearest-key string for the touches (empty when only predicting the next word).
    public var literal: String
    /// At most 3 slots, in display order. While typing a word: `[literal, best, alternative]` (the UI puts `best`
    /// in the middle). Next-word prediction (no touches): up to 3 slots, no literal.
    public var slots: [SuggestionSlot]
    /// Phrase chip that widens one slot (D-13). Always nil until M3-03.
    public var phrase: SuggestionSlot?
    public var autocorrect: AutocorrectProposal?
}
