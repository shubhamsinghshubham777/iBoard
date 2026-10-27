import Foundation

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
        return try parse(Data(contentsOf: url))
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
