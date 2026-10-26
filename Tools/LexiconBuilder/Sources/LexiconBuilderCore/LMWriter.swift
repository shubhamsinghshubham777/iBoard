import Foundation

public struct LMOptions: Sendable {
    public var minCount: UInt64
    public var maxBigrams: Int?
    public var maxTrigrams: Int?
    public init(minCount: UInt64 = 2, maxBigrams: Int? = nil, maxTrigrams: Int? = nil) {
        self.minCount = minCount; self.maxBigrams = maxBigrams; self.maxTrigrams = maxTrigrams
    }
}

struct LMStats { var bigrams = 0, trigrams = 0, droppedOOV = 0 }

struct TriKey: Comparable, Hashable {
    let a: UInt32, b: UInt32, c: UInt32
    init(_ v: [UInt32]) { a = v[0]; b = v[1]; c = v[2] }
    static func < (l: TriKey, r: TriKey) -> Bool { (l.a, l.b, l.c) < (r.a, r.b, r.c) }
}

/// Interpolated absolute-discounting 3-gram, pruned by count. See docs/LEXICON_FORMAT.md section 6.
func buildLM(ngrams: [[String]: UInt64], wordIds: [String: UInt32], vocab: Int, lexChecksum: UInt32,
             options: LMOptions) -> (file: [UInt8], stats: LMStats) {
    var stats = LMStats()
    var bi: [UInt64: UInt64] = [:]            // (w1<<32|w2) -> count
    var tri: [TriKey: UInt64] = [:]
    for (g, c) in ngrams {
        let ids = g.compactMap { wordIds[$0] }
        guard ids.count == g.count else { stats.droppedOOV += 1; continue }
        if ids.count == 2 { bi[UInt64(ids[0]) << 32 | UInt64(ids[1]), default: 0] += c }
        else { tri[TriKey(ids), default: 0] += c }
    }
    let D = LexFormat.discount
    // Context statistics come from the unpruned data.
    var uniCtx: [UInt32: (total: UInt64, types: Int)] = [:]
    for (k, c) in bi { let w1 = UInt32(k >> 32); var e = uniCtx[w1] ?? (0, 0); e.total += c; e.types += 1; uniCtx[w1] = e }
    var biCtx: [UInt64: (total: UInt64, types: Int)] = [:]
    for (k, c) in tri { let key = UInt64(k.a) << 32 | UInt64(k.b); var e = biCtx[key] ?? (0, 0); e.total += c; e.types += 1; biCtx[key] = e }

    func prune<K: Comparable>(_ d: [K: UInt64], max: Int?) -> [K] {
        var items = d.filter { $0.value >= options.minCount }.map { (key: $0.key, count: $0.value) }
        if let m = max, items.count > m {
            items.sort { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
            items = Array(items.prefix(m))
        }
        return items.map { $0.key }.sorted()
    }
    let triKeys = prune(tri, max: options.maxTrigrams)
    var biKeySet = Set(prune(bi, max: options.maxBigrams))
    for t in triKeys { biKeySet.insert(UInt64(t.a) << 32 | UInt64(t.b)) }   // contexts must exist to carry backoff weights
    let biKeys = biKeySet.sorted()
    func bow(_ e: (total: UInt64, types: Int)?) -> UInt16 {
        guard let e else { return 0 }   // no continuations known: weight 1.0
        return quantize(D * Double(e.types) / Double(e.total))
    }
    var uniBow = ByteWriter()
    for w in 0..<vocab { uniBow.u16(bow(uniCtx[UInt32(w)])); uniBow.u16(0) }
    var bw = ByteWriter()
    for k in biKeys {
        let c = Double(bi[k] ?? 0)
        let ctx = uniCtx[UInt32(k >> 32)]
        // Bigrams kept only as trigram contexts may have no bigram count: store p = 0 (max q).
        let pd = (c > 0 && ctx != nil) ? max(c - D, 0) / Double(ctx!.total) : 0
        bw.u32(UInt32(k >> 32)); bw.u32(UInt32(k & 0xFFFF_FFFF)); bw.u16(quantize(pd)); bw.u16(bow(biCtx[k]))
    }
    var tw = ByteWriter()
    for t in triKeys {
        let c = Double(tri[t] ?? 0)
        let ctx = biCtx[UInt64(t.a) << 32 | UInt64(t.b)]!
        tw.u32(t.a); tw.u32(t.b); tw.u32(t.c); tw.u16(quantize(max(c - D, 0) / Double(ctx.total))); tw.u16(0)
    }
    var meta = ByteWriter()
    meta.u32(UInt32(vocab)); meta.u32(lexChecksum)
    stats.bigrams = biKeys.count; stats.trigrams = triKeys.count
    let file = assembleContainer(magic: LexFormat.magicLM, sections: [
        SectionData(id: LexFormat.LMSection.meta.rawValue, count: 1, bytes: meta.bytes),
        SectionData(id: LexFormat.LMSection.unigramBackoff.rawValue, count: UInt32(vocab), bytes: uniBow.bytes),
        SectionData(id: LexFormat.LMSection.bigrams.rawValue, count: UInt32(biKeys.count), bytes: bw.bytes),
        SectionData(id: LexFormat.LMSection.trigrams.rawValue, count: UInt32(triKeys.count), bytes: tw.bytes),
    ])
    return (file, stats)
}
