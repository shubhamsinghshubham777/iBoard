import CoreGraphics
import Foundation
import IBoardLayout

// Long-press alternates (F1 / D-08): shown in the suggestion strip, never as a balloon. UIKit-free.

/// Static alternate tables (English/Latin plus URL suffixes). Hinglish / other languages come with M7.
public enum KeyAlternates {
    /// The long-press choice on the emoji key: not text, it opens the in-keyboard Quick Settings panel (which in turn has
    /// a row for the iOS Settings page; launching Settings is the one launch Guideline 4.4.1 allows, D-01).
    public static let settingsGlyph = "\u{2699}\u{FE0E}"
    /// Also on the emoji key (Full Access + clipboard history on): opens the clipboard history panel. Not text.
    public static let clipboardGlyph = "\u{1F4CB}"
    /// SF Symbol drawn for an action option (the glyph strings above are only identifiers, never inserted). nil: plain text.
    public static func symbolName(for option: String) -> String? {
        switch option {
        case settingsGlyph: "gearshape"
        case clipboardGlyph: "doc.on.clipboard"
        default: nil
        }
    }

    /// Spoken name of an action option, nil for plain text.
    public static func accessibilityLabel(for option: String) -> String? {
        switch option {
        case settingsGlyph: "Quick settings"
        case clipboardGlyph: "Clipboard history"
        default: nil
        }
    }

    private static let letters: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ", "ý"],
        "z": ["ž", "ź", "ż"],
    ]
    private static let symbols: [String: [String]] = [
        "-": ["–", "—", "•"],
        "$": ["₹", "€", "£", "¥", "¢"],
        "\"": ["“", "”", "„", "»", "«"],
        "'": ["‘", "’"],
        "?": ["¿"],
        "!": ["¡"],
        "0": ["°"],
        "&": ["§"],
        ".": ["…", "!", "?", ",", ";", ":"],
        ",": ["!", "?", ";", ":", "-", "(", ")", "…"],
    ]
    private static let suffixes: [String] = [".com", ".in", ".org", ".net", ".edu", ".co"]

    /// What a long press offers: for letters the key's hint symbol (its number / symbol, drawn faintly on the key) comes
    /// first, then the accented forms; other keys offer their `options`. nil: nothing to offer.
    public static func longPressOptions(for identity: KeyIdentity, uppercase: Bool = false, clipboardEntry: Bool = false) -> [String]? {
        if case .emoji = identity { return clipboardEntry ? [clipboardGlyph, settingsGlyph] : [settingsGlyph] } // the keyboard's way to the iOS Settings page for iBoard
        guard case .letter = identity else { return options(for: identity, uppercase: uppercase) }
        let accents = options(for: identity, uppercase: uppercase) ?? []
        let all = (KeyFlick.hint(for: identity).map { [$0] } ?? []) + accents
        return all.isEmpty ? nil : all
    }

    /// Alternates for a key (lowercase for letters; callers uppercase when shift is on), or nil.
    public static func options(for identity: KeyIdentity, uppercase: Bool = false) -> [String]? {
        switch identity {
        case .letter(let s):
            guard let o = letters[s] else { return nil }
            return uppercase ? o.map { $0.uppercased() } : o
        case .symbol(let s): return symbols[s]
        case .domainSuffix: return suffixes
        default: return nil
        }
    }
}

/// Slide-to-select state for the alternates row. Cells are laid out left to right, centred in the strip; the first
/// alternate starts highlighted (release without moving commits it). Sliding off the row back onto the key the
/// press started on cancels; release then inserts nothing.
public struct AlternatesSelection: Sendable, Equatable {
    public let options: [String]
    public let stripFrame: CGRect
    /// Touch region of the key the press started on.
    public let originRegion: CGRect
    public private(set) var highlighted: Int?
    private var hasLeftOrigin = false

    public static let maxCellWidth: CGFloat = 44

    public init(options: [String], stripFrame: CGRect, originRegion: CGRect) {
        self.options = options
        self.stripFrame = stripFrame
        self.originRegion = originRegion
        self.highlighted = options.isEmpty ? nil : 0
    }

    public var cellWidth: CGFloat {
        min(Self.maxCellWidth, stripFrame.width / CGFloat(max(options.count, 1)))
    }

    public var rowFrame: CGRect {
        let w = cellWidth * CGFloat(options.count)
        return CGRect(x: stripFrame.midX - w / 2, y: stripFrame.minY, width: w, height: stripFrame.height)
    }

    public func cellFrame(_ i: Int) -> CGRect {
        CGRect(x: rowFrame.minX + CGFloat(i) * cellWidth, y: stripFrame.minY, width: cellWidth, height: stripFrame.height)
    }

    public mutating func move(to p: CGPoint) {
        guard !options.isEmpty else { return }
        if p.y < stripFrame.maxY {
            // Over (or above) the strip: pick the cell by x, clamped to the row ends.
            hasLeftOrigin = true
            let i = Int(((p.x - rowFrame.minX) / cellWidth).rounded(.down))
            highlighted = min(max(i, 0), options.count - 1)
        } else if originRegion.contains(p) {
            if hasLeftOrigin { highlighted = nil } // slid back onto the original key: cancel
        } else {
            hasLeftOrigin = true // elsewhere on the keys: keep the last highlight
        }
    }

    /// The text to insert on release, or nil when cancelled.
    public mutating func end(at p: CGPoint) -> String? {
        move(to: p)
        guard let h = highlighted, h < options.count else { return nil }
        return options[h]
    }
}
