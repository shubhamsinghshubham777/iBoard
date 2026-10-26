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
/// Cancellation: `beginRequest()` is callable from any thread (the main actor, per keystroke) and returns a new
/// sequence number that also marks every older one stale. `submit` drops (returns nil) a request that is stale
/// when it starts, and again when it finishes, so the UI never applies out-of-date suggestions. The decode itself
/// is short and is not interrupted mid-way.
public actor EngineActor {
    private let lexicon: Lexicon
    private let model: NGramModel?
    private let parameters: TapDecoderParameters
    private var layout: KeyboardLayout
    private var decoder: TapDecoder
    private nonisolated let latest = Mutex<UInt64>(0)

    public init(layout: KeyboardLayout, lexicon: Lexicon, model: NGramModel? = nil,
                parameters: TapDecoderParameters = TapDecoderParameters()) {
        self.layout = layout
        self.lexicon = lexicon
        self.model = model
        self.parameters = parameters
        self.decoder = TapDecoder(layout: layout, lexicon: lexicon, model: model, parameters: parameters)
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
        decoder = TapDecoder(layout: layout, lexicon: lexicon, model: model, parameters: parameters)
    }

    /// Computes the strip for the request, or nil when it was superseded.
    public func submit(_ request: EngineRequest) -> Suggestions? {
        if isStale(request.sequence) { return nil }
        let ctx = context(for: request.previousWords)
        let out = request.touches.isEmpty ? predict(request, ctx) : typing(request, ctx)
        return isStale(request.sequence) ? nil : out
    }

    private func context(for words: [String]) -> LMContext {
        let ids = words.suffix(2).map { lexicon.lookup($0) }
        switch ids.count {
        case 2: return LMContext(older: ids[0], recent: ids[1])
        case 1: return LMContext(recent: ids[0])
        default: return .none
        }
    }

    private nonisolated static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    private func typing(_ r: EngineRequest, _ ctx: LMContext) -> Suggestions {
        let res: TapDecodeResult
        switch r.touches {
        case .hits(let h): res = decoder.decode(hits: h, layout: layout, context: ctx)
        case .points(let p): res = decoder.decode(points: p, context: ctx)
        }
        let up = r.capitalizeFirst
        let cap = { (s: String) -> String in up ? Self.capitalized(s) : s }
        let literalCandidate = res.candidates.first { $0.isLiteral }
        let literalIsWord = literalCandidate?.wordID != nil
        var seen: Set<String> = [res.literal]
        let others = res.candidates.filter { !$0.isLiteral && seen.insert($0.word).inserted }
        let showQuotes = !literalIsWord || res.autocorrect != nil
        var slots = [SuggestionSlot(text: cap(res.literal), role: .literal, showsQuotes: showQuotes,
                                    wordID: literalCandidate?.wordID, isCompletion: false)]
        for (i, c) in others.prefix(2).enumerated() {
            slots.append(SuggestionSlot(text: cap(c.word), role: i == 0 ? .best : .alternative, showsQuotes: false,
                                        wordID: c.wordID, isCompletion: c.isCompletion))
        }
        let proposal = res.autocorrect.map {
            AutocorrectProposal(word: cap($0.word), confidence: res.autocorrectConfidence, literalIsWord: literalIsWord)
        }
        return Suggestions(sequence: r.sequence, literal: res.literal, slots: slots, phrase: nil, autocorrect: proposal)
    }

    /// Next-word prediction (no touches): the most likely words under the context. Unigram candidates re-ranked
    /// by the n-gram model; real successor lists arrive with the phrase model (M3-02).
    private func predict(_ r: EngineRequest, _ ctx: LMContext) -> Suggestions {
        let up = r.capitalizeFirst
        let cap = { (s: String) -> String in up ? Self.capitalized(s) : s }
        let ids = lexicon.completions(prefix: "", limit: 64)
        let ranked = ids.map { ($0, model?.logProbability($0, context: ctx) ?? lexicon.logProbability(of: $0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let slots = ranked.prefix(3).enumerated().map { i, e in
            SuggestionSlot(text: cap(lexicon.word(of: e.0)), role: i == 0 ? .best : .alternative,
                           showsQuotes: false, wordID: e.0, isCompletion: false)
        }
        return Suggestions(sequence: r.sequence, literal: "", slots: slots, phrase: nil, autocorrect: nil)
    }
}
