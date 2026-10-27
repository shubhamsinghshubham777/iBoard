import Foundation

public struct EmojiSearchResult: Sendable, Hashable {
    public let entryIndex: Int
    public let score: Int
}

/// Keyword search and prediction over a catalog. Inverted index over normalised tokens
/// (sorted token array + postings, prefix lookup by binary search). Built once per catalog.
public struct EmojiSearchIndex: Sendable {
    public enum Field: UInt8, Sendable { case name = 4, hinglish = 3, keyword = 2 }

    private struct Posting: Sendable { let entry: Int32; let weight: UInt8 }

    public let catalog: EmojiCatalog
    private let tokens: [String]          // sorted, unique
    private let postings: [[Posting]]     // parallel to tokens
    private let nameLength: [Int]         // name tokens per entry (tie-break)

    public init(catalog: EmojiCatalog) {
        self.catalog = catalog
        nameLength = catalog.entries.map { EmojiSearchIndex.tokenize($0.name).count }
        var map: [String: [Posting]] = [:]
        for (i, e) in catalog.entries.enumerated() {
            var best: [String: UInt8] = [:]
            func add(_ text: String, _ f: Field) {
                for t in EmojiSearchIndex.tokenize(text) where (best[t] ?? 0) < f.rawValue { best[t] = f.rawValue }
            }
            add(e.name, .name)
            e.keywordsHinglish.forEach { add($0, .hinglish) }
            e.keywordsEN.forEach { add($0, .keyword) }
            e.keywordsHI.forEach { add($0, .keyword) }
            for (t, w) in best { map[t, default: []].append(Posting(entry: Int32(i), weight: w)) }
        }
        let keys = map.keys.sorted()
        tokens = keys
        postings = keys.map { map[$0]! }
    }

    /// Lowercase, NFC, split on anything that is not a letter/mark/number; Latin accents folded.
    public static func tokenize(_ text: String) -> [String] {
        // ASCII fast path (most keywords): no Foundation normalisation needed.
        var ascii = true
        for b in text.utf8 where b >= 0x80 { ascii = false; break }
        if ascii {
            var out: [String] = []
            var cur: [UInt8] = []
            for b in text.utf8 {
                switch b {
                case 0x30...0x39, 0x61...0x7A: cur.append(b)
                case 0x41...0x5A: cur.append(b + 32)
                default:
                    if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)); cur.removeAll(keepingCapacity: true) }
                }
            }
            if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
            return out
        }
        var out: [String] = []
        var cur = ""
        func flush() {
            if !cur.isEmpty { out.append(normalizeToken(cur)); cur = "" }
        }
        for ch in text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { cur.unicodeScalars.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    private static func normalizeToken(_ t: String) -> String {
        if t.unicodeScalars.allSatisfy({ $0.value < 0x250 }) {
            return t.folding(options: .diacriticInsensitive, locale: nil)
        }
        return t
    }

    /// Function words (English and common romanized Hindi) that must never trigger a prediction.
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "his", "has", "how", "its", "who", "with", "from", "that", "this", "have", "will", "your", "they", "what", "when",
        "into", "than", "then", "them", "were", "been", "over", "some", "also", "just", "very", "more", "like", "about",
        "hai", "hain", "ka", "ki", "ke", "ko", "se", "me", "mein", "aur", "nahi", "nahin", "kya", "ho", "tha", "thi",
        "hum", "tum", "aap", "yeh", "woh", "bhi", "par", "pe", "toh", "ek", "koi", "mera", "meri", "tera", "teri",
    ]

    private func lowerBound(_ prefix: String) -> Int {
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Ranked search. Every query token must match; the last token also matches as a prefix.
    /// Exact token hits score twice a prefix hit; name > Hinglish > keyword.
    public func search(_ query: String, limit: Int = 60) -> [EmojiSearchResult] {
        let qs = EmojiSearchIndex.tokenize(query)
        guard !qs.isEmpty, limit > 0 else { return [] }
        let n = catalog.entries.count
        var total = [Int](repeating: 0, count: n)
        var matched = [Int](repeating: 0, count: n)
        var best = [Int](repeating: 0, count: n)
        for (qi, q) in qs.enumerated() {
            let isLast = qi == qs.count - 1
            var touched: [Int32] = []
            var i = lowerBound(q)
            while i < tokens.count {
                let exact = tokens[i] == q
                if !exact && !(isLast && tokens[i].hasPrefix(q)) { break }
                for p in postings[i] {
                    let s = Int(p.weight) * (exact ? 2 : 1)
                    let e = Int(p.entry)
                    if best[e] == 0 { touched.append(p.entry) }
                    if s > best[e] { best[e] = s }
                }
                i += 1
            }
            for e32 in touched {
                let e = Int(e32)
                total[e] += best[e]; matched[e] += 1; best[e] = 0
            }
        }
        var res: [EmojiSearchResult] = []
        for e in 0..<n where matched[e] == qs.count { res.append(EmojiSearchResult(entryIndex: e, score: total[e])) }
        // Equal scores: the shorter name wins ("heart" -> red heart before "smiling face with heart-eyes").
        res.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = nameLength[$0.entryIndex], b = nameLength[$1.entryIndex]
            return a != b ? a < b : $0.entryIndex < $1.entryIndex
        }
        return Array(res.prefix(limit))
    }

    /// Emoji to offer after the user finished a word. Conservative on purpose: only exact word hits,
    /// and only when the emoji's name equals the word or the word is specific (few emoji carry it).
    public func predict(afterWord word: String, limit: Int = 3, maxSpecificity: Int = 4) -> [Int] {
        let ts = EmojiSearchIndex.tokenize(word)
        guard ts.count == 1, let t = ts.first, !Self.stopwords.contains(t) else { return [] }
        let minLen = t.unicodeScalars.allSatisfy({ $0.value < 0x250 }) ? 3 : 2
        guard t.unicodeScalars.count >= minLen else { return [] }
        let i = lowerBound(t)
        guard i < tokens.count, tokens[i] == t else { return [] }
        let list = postings[i]
        var scored: [(Int, Int)] = []
        for p in list {
            let e = Int(p.entry)
            let nameEqual = EmojiSearchIndex.tokenize(catalog.entries[e].name) == [t]
            if nameEqual { scored.append((e, 100)) }
            else if list.count <= maxSpecificity { scored.append((e, Int(p.weight))) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return scored.prefix(limit).map(\.0)
    }
}
