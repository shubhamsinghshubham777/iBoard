import Foundation

/// The two preceding words of a prediction, as lexicon ids. `nil` means "no context at that position".
public struct LMContext: Sendable, Equatable {
    /// Word before `recent`.
    public var older: Lexicon.WordID?
    /// Most recently typed word.
    public var recent: Lexicon.WordID?

    public init(older: Lexicon.WordID? = nil, recent: Lexicon.WordID? = nil) {
        self.older = older
        self.recent = recent
    }

    public static let none = LMContext()
}

/// Memory-mapped 3-gram language model (`.iblm`, docs/LEXICON_FORMAT.md sections 5 and 6): interpolated absolute
/// discounting with quantized probabilities. Bound to one lexicon (word ids), checked on open.
///
/// Scoring does not allocate: a binary search over the bigram / trigram tables per call.
public struct NGramModel: Sendable {
    public let lexicon: Lexicon
    private let file: MappedFile
    private let uniBow, bigrams, trigrams: Int
    public let bigramCount: Int
    public let trigramCount: Int

    public init(url: URL, lexicon: Lexicon, verifyChecksum: Bool = true) throws {
        try self.init(file: MappedFile(url: url), lexicon: lexicon, verifyChecksum: verifyChecksum)
    }

    public init(data: Data, lexicon: Lexicon, verifyChecksum: Bool = true) throws {
        try self.init(file: MappedFile(copying: data), lexicon: lexicon, verifyChecksum: verifyChecksum)
    }

    init(file: MappedFile, lexicon: Lexicon, verifyChecksum: Bool) throws {
        let c = try Container(file: file, magic: "IBLM", verifyChecksum: verifyChecksum)
        let meta = try c.section(1, recordSize: 8)
        guard meta.count >= 1, Int(file.u32(meta.offset)) == lexicon.wordCount,
              file.u32(meta.offset + 4) == lexicon.checksum else { throw LexiconFormatError.lexiconMismatch }
        let u = try c.section(2, recordSize: 4)
        let b = try c.section(3, recordSize: 12)
        let t = try c.section(4, recordSize: 16)
        guard u.count >= lexicon.wordCount else { throw LexiconFormatError.badRecordSize(2) }
        self.file = file
        self.lexicon = lexicon
        uniBow = u.offset
        bigrams = b.offset
        trigrams = t.offset
        bigramCount = b.count
        trigramCount = t.count
    }

    @inline(__always)
    private func prob(_ q: UInt16) -> Double { exp(-Double(q) / 2048) }

    /// Offset of the bigram record (a, b), if present.
    private func findBigram(_ a: UInt32, _ b: UInt32) -> Int? {
        var lo = 0
        var hi = bigramCount - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let o = bigrams + mid * 12
            let k1 = file.u32(o)
            let k2 = file.u32(o + 4)
            if k1 == a && k2 == b { return o }
            if k1 < a || (k1 == a && k2 < b) { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    private func findTrigram(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> Int? {
        var lo = 0
        var hi = trigramCount - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let o = trigrams + mid * 16
            let k1 = file.u32(o)
            let k2 = file.u32(o + 4)
            let k3 = file.u32(o + 8)
            if k1 == a && k2 == b && k3 == c { return o }
            if k1 < a || (k1 == a && (k2 < b || (k2 == b && k3 < c))) { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// The words most likely to follow `a` (and, when `older` is given, `older a`), by the stored bigram / trigram
    /// probabilities only (no backoff mass), best first. Used to seed next-word prediction with words that really
    /// follow the context instead of only globally frequent ones. Bigram and trigram records are sorted by key, so
    /// this is a binary search plus a scan of that word's records.
    public func successors(after a: Lexicon.WordID, older: Lexicon.WordID? = nil, limit: Int) -> [Lexicon.WordID] {
        var scored: [(id: Lexicon.WordID, p: Double)] = []
        let key = UInt32(a)
        var lo = 0, hi = bigramCount
        while lo < hi { // first record with k1 >= a
            let mid = (lo + hi) >> 1
            if file.u32(bigrams + mid * 12) < key { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < bigramCount, file.u32(bigrams + i * 12) == key {
            let o = bigrams + i * 12
            let q = file.u16(o + 8)
            if q != .max { scored.append((Lexicon.WordID(file.u32(o + 4)), prob(q))) }
            i += 1
        }
        if let older {
            let k1 = UInt32(older), k2 = key
            var tl = 0, th = trigramCount
            while tl < th { // first record with (k1, k2) >= (older, a)
                let mid = (tl + th) >> 1
                let o = trigrams + mid * 16
                let a1 = file.u32(o), a2 = file.u32(o + 4)
                if a1 < k1 || (a1 == k1 && a2 < k2) { tl = mid + 1 } else { th = mid }
            }
            var j = tl
            while j < trigramCount {
                let o = trigrams + j * 16
                guard file.u32(o) == k1, file.u32(o + 4) == k2 else { break }
                let q = file.u16(o + 12)
                if q != .max { scored.append((Lexicon.WordID(file.u32(o + 8)), prob(q) * 4)) } // trigram evidence first
                j += 1
            }
        }
        var best: [Lexicon.WordID: Double] = [:]
        for e in scored { best[e.id] = max(best[e.id] ?? 0, e.p) }
        return best.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    /// P1(w), from the lexicon.
    public func unigramProbability(_ w: Lexicon.WordID) -> Double {
        prob(lexicon.quantizedScore(of: w))
    }

    /// P2(w | a) = pd(a, w) + bow(a) * P1(w).
    public func bigramProbability(_ w: Lexicon.WordID, after a: Lexicon.WordID) -> Double {
        var p = prob(file.u16(uniBow + Int(a) * 4)) * unigramProbability(w)
        if let o = findBigram(a, w) {
            let q = file.u16(o + 8)
            if q != .max { p += prob(q) }
        }
        return p
    }

    /// P3(w | a, b) = pd(a, b, w) + bow(a, b) * P2(w | b); falls back to P2 when (a, b) was never seen.
    public func trigramProbability(_ w: Lexicon.WordID, after a: Lexicon.WordID, _ b: Lexicon.WordID) -> Double {
        let lower = bigramProbability(w, after: b)
        guard let ctx = findBigram(a, b) else { return lower }
        var p = prob(file.u16(ctx + 10)) * lower
        if let o = findTrigram(a, b, w) {
            let q = file.u16(o + 12)
            if q != .max { p += prob(q) }
        }
        return p
    }

    /// Probability of `w` given up to two preceding words (uses the longest available context).
    public func probability(_ w: Lexicon.WordID, context: LMContext) -> Double {
        guard let recent = context.recent else { return unigramProbability(w) }
        guard let older = context.older else { return bigramProbability(w, after: recent) }
        return trigramProbability(w, after: older, recent)
    }

    /// Natural log of `probability`. Floored so a zero (sub-normalised) result cannot produce -infinity.
    public func logProbability(_ w: Lexicon.WordID, context: LMContext) -> Double {
        log(max(probability(w, context: context), 1e-30))
    }
}
