import Foundation
import IBoardLayout

// Input controller logic (M1-05). UIKit-free so it is testable with `swift test`: the keyboard target adapts
// `UITextDocumentProxy` to `TextProxy`. Typed text is only ever passed through (insert / delete) or inspected
// transiently for capitalisation and word-delete decisions; nothing is stored or logged.

/// Mirror of `UITextAutocapitalizationType`.
public enum AutoCapMode: Sendable, Equatable {
    case none, words, sentences, allCharacters
}

public enum AutoCapitalizer {
    /// Sentence terminators (Latin, Devanagari danda, CJK, Arabic question mark, ellipsis).
    static let terminators: Set<Character> = [".", "!", "?", "\u{2026}", "\u{0964}", "\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{061F}"]
    /// Characters that may sit between a terminator and the following space: `He said "go." ` -> capital.
    static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}"]

    /// Shift state the keyboard should show for the text before the cursor.
    /// `before` is `documentContextBeforeInput` (capped at 500 chars, crosses paragraphs: P-24); nil/empty means the
    /// start of the document. No abbreviation handling ("e.g. " capitalises): estimated, refine in F2.
    public static func shift(mode: AutoCapMode, before: String?) -> ShiftState {
        let text = before ?? ""
        switch mode {
        case .none: return .off
        case .allCharacters: return .capsLock
        case .words:
            guard let last = text.last else { return .once }
            return last.isWhitespace ? .once : .off
        case .sentences:
            return startsSentence(text) ? .once : .off
        }
    }

    static func startsSentence(_ text: String) -> Bool {
        var spaces = 0
        var i = text.endIndex
        while i > text.startIndex {
            let p = text.index(before: i)
            let ch = text[p]
            if ch.isNewline { return true }
            if ch.isWhitespace { spaces += 1; i = p } else { break }
        }
        if i == text.startIndex { return true } // empty or only blanks since document start
        guard spaces > 0 else { return false } // "Hello." (no space yet) or mid-word
        var j = i
        while j > text.startIndex, closers.contains(text[text.index(before: j)]) { j = text.index(before: j) }
        guard j > text.startIndex else { return false }
        return terminators.contains(text[text.index(before: j)])
    }
}

/// What the return key shows and how it is coloured (F1: label/colour from `returnKeyType`).
public enum ReturnKeyStyle {
    /// Text label, or nil when the key shows a glyph (emergency call). Lowercase like the system keyboard (estimated).
    public static func label(for kind: ReturnKeyKind) -> String? {
        switch kind {
        case .default: "return"
        case .go: "go"
        case .google, .yahoo, .search: "search"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .send: "send"
        case .done: "done"
        case .continue: "continue"
        case .emergencyCall: nil
        }
    }

    /// Accent-coloured (blue) key vs plain grey key.
    public static func isProminent(_ kind: ReturnKeyKind) -> Bool {
        switch kind {
        case .default, .next, .emergencyCall: false
        default: true
        }
    }
}

/// The slice of `UITextDocumentProxy` the controller needs.
public protocol TextProxy: AnyObject {
    var contextBefore: String? { get }
    var hasText: Bool { get }
    func insert(_ text: String)
    func deleteBackwardOnce()
}

public struct InputFieldTraits: Sendable, Equatable {
    public var autoCap: AutoCapMode
    public var enablesReturnKeyAutomatically: Bool
    public init(autoCap: AutoCapMode = .sentences, enablesReturnKeyAutomatically: Bool = false) {
        self.autoCap = autoCap
        self.enablesReturnKeyAutomatically = enablesReturnKeyAutomatically
    }
}

public final class InputController {
    public let proxy: TextProxy
    public var traits: InputFieldTraits

    public init(proxy: TextProxy, traits: InputFieldTraits = InputFieldTraits()) {
        self.proxy = proxy
        self.traits = traits
    }

    public func insert(_ text: String) { proxy.insert(text) }

    /// Deletes one user-perceived character (one call to the proxy; see `GraphemeDelete` notes in the M1-05 result).
    public func deleteBackward() { proxy.deleteBackwardOnce() }

    /// Delete the previous word with its trailing whitespace, grapheme by grapheme.
    public func deleteWord() {
        let n = max(wordDeleteCount(before: proxy.contextBefore ?? ""), 1)
        for _ in 0..<n { proxy.deleteBackwardOnce() }
    }

    /// False when the field asked for `enablesReturnKeyAutomatically` and has no text.
    public var isReturnKeyEnabled: Bool { !traits.enablesReturnKeyAutomatically || proxy.hasText }

    /// Inserts a newline unless the return key is disabled. Returns whether it acted.
    @discardableResult
    public func returnKey() -> Bool {
        guard isReturnKeyEnabled else { return false }
        proxy.insert("\n")
        return true
    }

    public func autoShift() -> ShiftState {
        AutoCapitalizer.shift(mode: traits.autoCap, before: proxy.contextBefore)
    }
}
