import Foundation

/// Reference reader used to verify round-trips. The production mmap reader is M2-02.
public struct LexiconReader {
    let c: Container
    let strings, words, nodes, edges: (offset: Int, length: Int, count: Int)
    public var checksum: UInt32 { c.checksum }
    public var wordCount: Int { words.count }

    public init(data: Data) throws {
        c = try Container(data: data, magic: LexFormat.magicLexicon)
        strings = try c.section(LexFormat.LexSection.strings.rawValue)
        words = try c.section(LexFormat.LexSection.words.rawValue)
        nodes = try c.section(LexFormat.LexSection.nodes.rawValue)
        edges = try c.section(LexFormat.LexSection.edges.rawValue)
    }

    public func word(id: UInt32) -> String {
        let o = words.offset + Int(id) * 8
        let s = strings.offset + Int(c.u32(o)), len = Int(c.u16(o + 4))
        return String(decoding: c.data[s..<(s + len)], as: UTF8.self)
    }

    /// Quantized neg-log-prob of a word id.
    public func quantizedScore(id: UInt32) -> UInt16 { c.u16(words.offset + Int(id) * 8 + 6) }
    /// Natural-log unigram probability.
    public func logProb(id: UInt32) -> Double { -Double(quantizedScore(id: id)) / LexFormat.quantScale }

    private func child(of node: Int, label: UInt32) -> Int? {
        let o = nodes.offset + node * 12
        let start = Int(c.u32(o)), n = Int(c.u16(o + 8))
        var lo = 0, hi = n - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let e = edges.offset + (start + mid) * 8
            let l = c.u32(e)
            if l == label { return Int(c.u32(e + 4)) }
            if l < label { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    private func walk(_ s: String) -> Int? {
        var n = 0
        for sc in normalize(s).unicodeScalars { guard let nx = child(of: n, label: sc.value) else { return nil }; n = nx }
        return n
    }

    /// Exact lookup. Returns the word id.
    public func lookup(_ s: String) -> UInt32? {
        guard let n = walk(s) else { return nil }
        let id = c.u32(nodes.offset + n * 12 + 4)
        return id == LexFormat.noWord ? nil : id
    }

    public func score(_ s: String) -> Double? { lookup(s).map { logProb(id: $0) } }

    /// All words starting with `prefix`, best score first (ties: word id order).
    public func completions(prefix: String, limit: Int = .max) -> [(word: String, id: UInt32)] {
        guard let start = walk(prefix) else { return [] }
        var found: [UInt32] = []
        var stack = [start]
        while let n = stack.popLast() {
            let o = nodes.offset + n * 12
            let id = c.u32(o + 4)
            if id != LexFormat.noWord { found.append(id) }
            let first = Int(c.u32(o)), cnt = Int(c.u16(o + 8))
            for i in 0..<cnt { stack.append(Int(c.u32(edges.offset + (first + i) * 8 + 4))) }
        }
        found.sort()   // ids are ranked by frequency
        return found.prefix(limit).map { (word: word(id: $0), id: $0) }
    }
}

public struct LMReader {
    let c: Container
    let lex: LexiconReader
    let uniBow, bigrams, trigrams: (offset: Int, length: Int, count: Int)

    public init(data: Data, lexicon: LexiconReader) throws {
        c = try Container(data: data, magic: LexFormat.magicLM)
        let meta = try c.section(LexFormat.LMSection.meta.rawValue)
        guard Int(c.u32(meta.offset)) == lexicon.wordCount, c.u32(meta.offset + 4) == lexicon.checksum else { throw LexError.invalidInput("LM does not match lexicon") }
        lex = lexicon
        uniBow = try c.section(LexFormat.LMSection.unigramBackoff.rawValue)
        bigrams = try c.section(LexFormat.LMSection.bigrams.rawValue)
        trigrams = try c.section(LexFormat.LMSection.trigrams.rawValue)
    }

    public var bigramCount: Int { bigrams.count }
    public var trigramCount: Int { trigrams.count }

    private func findBigram(_ a: UInt32, _ b: UInt32) -> Int? {
        var lo = 0, hi = bigrams.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, o = bigrams.offset + mid * 12
            let k = (c.u32(o), c.u32(o + 4))
            if k == (a, b) { return o }
            if k < (a, b) { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    private func findTrigram(_ a: UInt32, _ b: UInt32, _ x: UInt32) -> Int? {
        var lo = 0, hi = trigrams.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, o = trigrams.offset + mid * 16
            let k = (c.u32(o), c.u32(o + 4), c.u32(o + 8))
            if k == (a, b, x) { return o }
            if k < (a, b, x) { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// P(word | w1) with interpolation, as a probability.
    public func probability(_ w: UInt32, given w1: UInt32) -> Double {
        let uni = dequantize(lex.quantizedScore(id: w))
        let bow = dequantize(c.u16(uniBow.offset + Int(w1) * 4))
        var p = bow * uni
        if let o = findBigram(w1, w) { p += c.u16(o + 8) == .max ? 0 : dequantize(c.u16(o + 8)) }
        return p
    }

    /// P(word | w1 w2) with interpolation, as a probability.
    public func probability(_ w: UInt32, given w1: UInt32, _ w2: UInt32) -> Double {
        let lower = probability(w, given: w2)
        guard let ctx = findBigram(w1, w2) else { return lower }
        var p = dequantize(c.u16(ctx + 10)) * lower
        if let o = findTrigram(w1, w2, w) { p += c.u16(o + 12) == .max ? 0 : dequantize(c.u16(o + 12)) }
        return p
    }
}
