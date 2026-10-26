import Foundation

public enum Autocapitalization: Sendable, Equatable {
    case none, words, sentences, allCharacters
}

/// Opening / closing quote characters (locale hook; English by default).
public struct QuoteStyle: Sendable, Equatable {
    public var openDouble: Character, closeDouble: Character, openSingle: Character, closeSingle: Character

    public init(openDouble: Character, closeDouble: Character, openSingle: Character, closeSingle: Character) {
        self.openDouble = openDouble
        self.closeDouble = closeDouble
        self.openSingle = openSingle
        self.closeSingle = closeSingle
    }

    public static let english = QuoteStyle(openDouble: "\u{201C}", closeDouble: "\u{201D}",
                                           openSingle: "\u{2018}", closeSingle: "\u{2019}")
}

/// Text-input trait values that drive punctuation behaviour.
public struct PunctuationTraits: Sendable, Equatable {
    public var autocapitalization: Autocapitalization
    public var smartQuotes: TraitSwitch
    public var smartDashes: TraitSwitch
    /// Double space becomes ". ". The caller turns this off for URL / email / number fields.
    public var doubleSpacePeriod: Bool
    public var quotes: QuoteStyle

    public init(autocapitalization: Autocapitalization = .sentences, smartQuotes: TraitSwitch = .default,
                smartDashes: TraitSwitch = .default, doubleSpacePeriod: Bool = true, quotes: QuoteStyle = .english) {
        self.autocapitalization = autocapitalization
        self.smartQuotes = smartQuotes
        self.smartDashes = smartDashes
        self.doubleSpacePeriod = doubleSpacePeriod
        self.quotes = quotes
    }
}

public struct ContractionSuggestion: Sendable, Equatable {
    public var typed: String
    public var replacement: String
    /// True only for an unambiguous apostrophe-less form at high confidence; otherwise suggestion strip only.
    public var isAutoApplicable: Bool

    public init(typed: String, replacement: String, isAutoApplicable: Bool) {
        self.typed = typed
        self.replacement = replacement
        self.isAutoApplicable = isAutoApplicable
    }
}

/// Pure punctuation / capitalisation logic over (left context, traits, event) -> edits.
///
/// `leftContext` is `documentContextBeforeInput` (capped at 500 characters by iOS and possibly spanning paragraphs,
/// P-24). All scanning works on Characters (grapheme clusters), so emoji and combining marks are never split;
/// `TextEdit.deleteBackward` counts Characters too. An empty context means the start of the document.
public enum SmartPunctuation {
    // MARK: Auto-capitalization

    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "»", "\u{203A}"]
    private static let openers: Set<Character> = ["(", "[", "{", "<", "\"", "'", "\u{201C}", "\u{2018}", "«", "\u{2039}", "/", "\u{2014}", "\u{2013}", "-"]
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "cf", "approx", "no", "fig", "inc", "ltd", "co",
    ]

    /// Whether the next typed letter should be uppercase (shift should be on).
    public static func shouldAutocapitalize(leftContext: String, mode: Autocapitalization) -> Bool {
        switch mode {
        case .none: return false
        case .allCharacters: return true
        case .words:
            guard let last = leftContext.last else { return true }
            return last.isWhitespace
        case .sentences:
            return atSentenceStart(leftContext)
        }
    }

    private static func atSentenceStart(_ ctx: String) -> Bool {
        var i = ctx.endIndex
        var sawWhitespace = false
        var sawNewline = false
        while i > ctx.startIndex {
            let p = ctx.index(before: i)
            let c = ctx[p]
            guard c.isWhitespace else { break }
            sawWhitespace = true
            if c.isNewline { sawNewline = true }
            i = p
        }
        if i == ctx.startIndex { return true }          // empty / whitespace only: start of the document
        if sawNewline { return true }                    // new paragraph or line
        guard sawWhitespace else { return false }        // "Hello." with no space yet
        while i > ctx.startIndex, closers.contains(ctx[ctx.index(before: i)]) { i = ctx.index(before: i) }
        guard i > ctx.startIndex else { return false }
        let t = ctx[ctx.index(before: i)]
        guard terminators.contains(t) else { return false }
        if t == "." {
            var j = ctx.index(before: i)
            var token = ""
            while j > ctx.startIndex {
                let q = ctx.index(before: j)
                let ch = ctx[q]
                guard ch.isLetter || ch == "." else { break }
                token.insert(ch, at: token.startIndex)
                j = q
            }
            let lower = token.lowercased()
            if abbreviations.contains(lower) { return false }
            if token.count == 1, let only = token.first, only.isLetter, !"IaA".contains(only) { return false }  // initials
            if token.contains("."), token.count <= 5 { return false }                                           // "e.g", "U.S"
        }
        return true
    }

    // MARK: Edits for inserted text

    /// The edit to apply when the user types `text` (a single key's output). Anything that is not a space, quote or
    /// hyphen passes through unchanged.
    public static func edit(forInserting text: String, leftContext: String, traits: PunctuationTraits) -> TextEdit {
        switch text {
        case " ": return spaceEdit(leftContext, traits)
        case "\"", "'": return traits.smartQuotes.isEnabled ? quoteEdit(text, leftContext, traits.quotes) : TextEdit(insert: text)
        case "-": return traits.smartDashes.isEnabled ? dashEdit(leftContext) : TextEdit(insert: text)
        default: return TextEdit(insert: text)
        }
    }

    private static func spaceEdit(_ ctx: String, _ traits: PunctuationTraits) -> TextEdit {
        guard traits.doubleSpacePeriod, ctx.last == " " else { return TextEdit(insert: " ") }
        let before = ctx.dropLast()
        guard let prev = before.last, !prev.isWhitespace else { return TextEdit(insert: " ") }
        let noPeriodAfter: Set<Character> = [".", "!", "?", ",", ";", ":", "…", "(", "[", "{", "\u{201C}", "\u{2018}", "-", "\u{2014}", "\u{2013}"]
        guard !noPeriodAfter.contains(prev) else { return TextEdit(insert: " ") }
        return TextEdit(deleteBackward: 1, insert: ". ")
    }

    private static func isOpeningPosition(after prev: Character?) -> Bool {
        guard let p = prev else { return true }
        return p.isWhitespace || openers.contains(p)
    }

    private static func quoteEdit(_ q: String, _ ctx: String, _ s: QuoteStyle) -> TextEdit {
        let prev = ctx.last
        if q == "\"" {
            return TextEdit(insert: String(isOpeningPosition(after: prev) ? s.openDouble : s.closeDouble))
        }
        // Apostrophe inside or at the end of a word is always the closing form (don't, dogs').
        if let p = prev, p.isLetter || p.isNumber { return TextEdit(insert: String(s.closeSingle)) }
        return TextEdit(insert: String(isOpeningPosition(after: prev) ? s.openSingle : s.closeSingle))
    }

    private static func dashEdit(_ ctx: String) -> TextEdit {
        guard ctx.last == "-" else { return TextEdit(insert: "-") }
        // "---" stays hyphens (horizontal rule / markdown): only convert a pair not preceded by another hyphen.
        if ctx.dropLast().last == "-" { return TextEdit(insert: "-") }
        return TextEdit(deleteBackward: 1, insert: "\u{2014}")
    }

    // MARK: Word extraction and contractions

    /// The word being typed: trailing letters, digits and apostrophes of the left context.
    public static func wordBeforeCursor(_ leftContext: String) -> String {
        var out = ""
        for c in leftContext.reversed() {
            guard c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" else { break }
            out.insert(c, at: out.startIndex)
        }
        return out
    }

    /// (replacement, prior confidence that the apostrophe-less word is meant as the contraction).
    private static let contractions: [String: (String, Double)] = [
        "dont": ("don't", 0.999), "cant": ("can't", 0.999), "doesnt": ("doesn't", 0.999), "didnt": ("didn't", 0.999),
        "isnt": ("isn't", 0.999), "arent": ("aren't", 0.999), "wasnt": ("wasn't", 0.999), "werent": ("weren't", 0.999),
        "hasnt": ("hasn't", 0.999), "havent": ("haven't", 0.999), "hadnt": ("hadn't", 0.999), "wouldnt": ("wouldn't", 0.999),
        "couldnt": ("couldn't", 0.999), "shouldnt": ("shouldn't", 0.999), "mustnt": ("mustn't", 0.999),
        "im": ("I'm", 0.995), "ive": ("I've", 0.995), "youre": ("you're", 0.995), "theyre": ("they're", 0.995),
        "thats": ("that's", 0.99), "whats": ("what's", 0.99), "youve": ("you've", 0.995), "theyve": ("they've", 0.995),
        "youll": ("you'll", 0.99), "theyll": ("they'll", 0.99), "weve": ("we've", 0.99),
        // Real words as well: suggestion only, never automatic.
        "wont": ("won't", 0.9), "ill": ("I'll", 0.5), "id": ("I'd", 0.5), "hes": ("he's", 0.6), "shes": ("she's", 0.6),
        "lets": ("let's", 0.5), "were": ("we're", 0.2), "well": ("we'll", 0.1), "its": ("it's", 0.4),
    ]

    /// Contraction for a typed apostrophe-less word. `contextConfidence` (0...1, default 1) scales the table's prior
    /// when the caller has evidence against it. Auto-applicable only when prior * context >= `autoThreshold`.
    public static func contraction(forWord typed: String, contextConfidence: Double = 1,
                                   autoThreshold: Double = 0.98) -> ContractionSuggestion? {
        guard let (base, prior) = contractions[typed.lowercased()] else { return nil }
        var rep = base
        if typed.count > 1, typed == typed.uppercased(), typed != typed.lowercased() {
            rep = base.uppercased()
        } else if let f = typed.first, f.isUppercase, let b = base.first, b.isLowercase {
            rep = b.uppercased() + base.dropFirst()
        }
        return ContractionSuggestion(typed: typed, replacement: rep, isAutoApplicable: prior * contextConfidence >= autoThreshold)
    }
}
