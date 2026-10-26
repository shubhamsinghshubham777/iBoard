import CoreGraphics
import Foundation
import IBoardEngine
import IBoardLayout

// Swipe decoding off the main thread (M4-03). The engine package's `EngineActor` has no swipe entry point yet, so
// this actor owns a `SwipeDecoder` of its own. It shares the lexicon / language model with the tap engine (same
// memory-mapped files, no second copy). Words and paths exist only for the duration of one call.

/// Ranked words for one swipe, best first (at most three; the strip has three slots).
public struct SwipeOutcome: Sendable, Equatable {
    public var words: [String]
    public var confidence: Double
    public init(words: [String], confidence: Double = 0) {
        self.words = words
        self.confidence = confidence
    }
}

public protocol SwipeDecoding: Sendable {
    /// `nil` when the path was too short to be a swipe or nothing matched.
    func decode(points: [SwipePoint], previousWords: [String]) async -> SwipeOutcome?
    func updateLayout(_ layout: KeyboardLayout) async
}

public actor SwipeEngine: SwipeDecoding {
    private let lexicon: Lexicon
    private let model: NGramModel?
    private let parameters: SwipeParameters
    private let personal: (@Sendable () async -> (any PersonalScoreProvider)?)?
    private var layout: KeyboardLayout

    /// - Parameter personal: asked once per decode for the current personal-model snapshot (nil: no personal model).
    public init(layout: KeyboardLayout, lexicon: Lexicon, model: NGramModel? = nil,
                parameters: SwipeParameters = SwipeParameters(),
                personal: (@Sendable () async -> (any PersonalScoreProvider)?)? = nil) {
        self.layout = layout
        self.lexicon = lexicon
        self.model = model
        self.parameters = parameters
        self.personal = personal
    }

    public func updateLayout(_ layout: KeyboardLayout) {
        self.layout = layout
    }

    public func decode(points: [SwipePoint], previousWords: [String]) async -> SwipeOutcome? {
        guard layout.kind == .letters else { return nil }
        let snapshot = await personal?()
        // Cheap (one pass over ~30 letter keys); rebuilt per swipe so the personal snapshot is current.
        let decoder = SwipeDecoder(layout: layout, lexicon: lexicon, model: model, personal: snapshot, parameters: parameters)
        let ids = previousWords.suffix(2).map { lexicon.lookup($0) }
        let ctx: LMContext
        switch ids.count {
        case 2: ctx = LMContext(older: ids[0], recent: ids[1])
        case 1: ctx = LMContext(recent: ids[0])
        default: ctx = .none
        }
        let r = decoder.decode(points: points, context: ctx, contextWords: Array(previousWords.suffix(2)))
        guard r.isSwipe, !r.candidates.isEmpty else { return nil }
        var seen = Set<String>()
        let words = r.candidates.map(\.word).filter { seen.insert($0).inserted }.prefix(3)
        return SwipeOutcome(words: Array(words), confidence: r.confidence)
    }
}

/// Spacing and casing rules around a swiped word (F3: auto-space before, implied space after).
public enum SwipeSpacing {
    /// Characters after which a swiped word follows without a space (openers, joiners).
    static let noSpaceAfter: Set<Character> = [
        "(", "[", "{", "<", "\"", "\u{201C}", "\u{2018}", "'", "/", "\\", "-", "\u{2013}", "\u{2014}", "@", "#", "$",
        "_", "\u{00AB}", "\u{00A1}", "\u{00BF}",
    ]
    /// Punctuation that pulls back the implied space after a swiped word when typed next.
    public static let closers: Set<String> = [".", ",", ";", ":", "!", "?", ")"]

    /// Whether a space must be inserted before a swiped word, given the text before the cursor (nil / empty: start
    /// of the field).
    public static func needsSpace(before leftContext: String?) -> Bool {
        guard let last = leftContext?.last else { return false }
        if last.isWhitespace || last.isNewline { return false }
        return !noSpaceAfter.contains(last)
    }

    /// `word` with the shift state applied (`once`: first letter, `capsLock`: all).
    public static func cased(_ word: String, shift: ShiftState) -> String {
        switch shift {
        case .off: return word
        case .capsLock: return word.uppercased()
        case .once:
            guard let f = word.first else { return word }
            return f.uppercased() + word.dropFirst()
        }
    }
}
