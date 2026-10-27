import Foundation

/// The emoji search query typed on the keyboard's own keys (the keyboard cannot focus a text field). Pure; lives in
/// memory only while the search is open and is never stored or logged.
public struct EmojiSearchBuffer: Sendable, Equatable {
    public static let maxLength = 24
    public private(set) var text = ""
    public init() {}

    public var isEmpty: Bool { text.isEmpty }

    /// Letters, digits and single inner spaces are kept (any script); other input is ignored. Returns whether it changed.
    @discardableResult
    public mutating func append(_ input: String) -> Bool {
        var changed = false
        for ch in input {
            guard text.count < Self.maxLength else { break }
            if ch.isLetter || ch.isNumber || Self.isMark(ch) {
                text.append(ch); changed = true
            } else if ch == " ", !text.isEmpty, text.last != " " {
                text.append(ch); changed = true
            }
        }
        return changed
    }

    @discardableResult
    public mutating func deleteBackward() -> Bool {
        guard !text.isEmpty else { return false }
        text.removeLast()
        return true
    }

    private static func isMark(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: true
            default: false
            }
        }
    }

    public mutating func clear() { text = "" }

    /// Query for the index: trailing space trimmed.
    public var query: String { text.trimmingCharacters(in: .whitespaces) }
}
