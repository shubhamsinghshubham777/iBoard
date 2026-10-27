import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// Skin tone modifiers in Fitzpatrick order (light ... dark).
public enum SkinTone: Int, CaseIterable, Codable, Sendable {
    case light = 0, mediumLight, medium, mediumDark, dark

    /// The modifier scalar (U+1F3FB ... U+1F3FF) used as the picker swatch.
    public var swatch: String {
        String(UnicodeScalar(0x1F3FB + UInt32(rawValue))!)
    }
}

/// One base emoji (never a skin-tone variant; those hang off `tones`).
public struct EmojiEntry: Sendable, Hashable {
    public let emoji: String
    /// Index into `EmojiCatalog.groups`.
    public let group: Int
    /// Canonical English name from emoji-test.txt, e.g. "pizza".
    public let name: String
    public let keywordsEN: [String]
    public let keywordsHI: [String]
    /// Project-authored romanized Hindi keywords (Hinglish).
    public let keywordsHinglish: [String]
    /// The five uniform skin-tone variants (light ... dark), empty if the emoji has none.
    public let tones: [String]

    public var supportsSkinTone: Bool { tones.count == SkinTone.allCases.count }

    public func variant(_ tone: SkinTone?) -> String {
        guard let tone, supportsSkinTone else { return emoji }
        return tones[tone.rawValue]
    }
}

public enum EmojiCatalogError: Error, Equatable {
    case resourceMissing
    case malformed
}

/// Immutable emoji data loaded from the generated `emoji.json` resource.
public struct EmojiCatalog: Sendable {
    public let groups: [String]
    public let entries: [EmojiEntry]
    public let source: String

    public init(groups: [String], entries: [EmojiEntry], source: String = "") {
        self.groups = groups
        self.entries = entries
        self.source = source
    }

    public static func loadBundled() throws -> EmojiCatalog {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json") else {
            throw EmojiCatalogError.resourceMissing
        }
        return try parse(Data(contentsOf: url)).droppingUnrenderable()
    }

    /// The data is Emoji 18.0; an older iOS has no glyph for the newest ones and draws a "?" box. Entries whose scalars
    /// the system emoji font cannot draw are dropped (their skin-tone variants go with them).
    public func droppingUnrenderable() -> EmojiCatalog {
        #if canImport(CoreText)
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        func drawable(_ s: String) -> Bool {
            for u in s.unicodeScalars where u.value != 0x200D && u.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains(u.value) {
                var chars = [UniChar](String(u).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: chars.count)
                if !CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count) { return false }
            }
            return true
        }
        guard drawable("\u{1F600}") else { return self } // font lookup failed: filter nothing rather than everything
        let kept = entries.filter { drawable($0.emoji) }
        return kept.count == entries.count ? self : EmojiCatalog(groups: groups, entries: kept, source: source)
        #else
        return self
        #endif
    }

    public static func parse(_ data: Data) throws -> EmojiCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? Int == 1,
              let groups = root["groups"] as? [String],
              let rows = root["e"] as? [[Any]] else { throw EmojiCatalogError.malformed }
        func split(_ s: String) -> [String] {
            s.isEmpty ? [] : s.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
        }
        var entries: [EmojiEntry] = []
        entries.reserveCapacity(rows.count)
        for r in rows {
            guard r.count == 7, let emoji = r[0] as? String, let g = r[1] as? Int,
                  let name = r[2] as? String, let en = r[3] as? String, let hi = r[4] as? String,
                  let tones = r[5] as? String, let hl = r[6] as? String,
                  groups.indices.contains(g) else { throw EmojiCatalogError.malformed }
            entries.append(EmojiEntry(
                emoji: emoji, group: g, name: name,
                keywordsEN: split(en), keywordsHI: split(hi),
                keywordsHinglish: hl.split(separator: " ").map(String.init), tones: split(tones)))
        }
        return EmojiCatalog(groups: groups, entries: entries, source: root["source"] as? String ?? "")
    }

    /// Entry indices per group, in catalog (Unicode CLDR) order.
    public func indices(inGroup group: Int) -> [Int] {
        entries.indices.filter { entries[$0].group == group }
    }
}
