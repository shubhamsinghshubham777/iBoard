import Foundation

/// Position in the lexicon trie. A plain index, so beam search can keep thousands of these without allocating.
public struct TrieCursor: Sendable, Hashable {
    public let node: UInt32
    @inline(__always) init(node: UInt32) { self.node = node }
}

/// Reusable scratch for `Lexicon.completions`. Pass the same value across calls to avoid reallocating.
public struct CompletionScratch: Sendable {
    var heap: [UInt64] = []
    public init() { heap.reserveCapacity(512) }
}

/// Memory-mapped lexicon (`.iblex`, docs/LEXICON_FORMAT.md section 4): word table plus a trie with quantized
/// unigram log-probabilities.
///
/// Lookups read straight from the mapping and do not allocate. Input strings must already be NFC (the builder
/// normalizes the words; keyboard input is NFC) and in the same case as the lexicon (lowercase for the shipped
/// lexicons): the reader does no normalization at runtime.
public struct Lexicon: Sendable {
    public typealias WordID = UInt32

    private let file: MappedFile
    private let strings, words, nodes, edges: Int
    public let wordCount: Int
    public let nodeCount: Int
    /// Header checksum of the file; the paired LM stores it.
    public let checksum: UInt32

    static let noWord: UInt32 = 0xFFFF_FFFF
    static let quantScale: Double = 2048

    public init(url: URL, verifyChecksum: Bool = true) throws {
        try self.init(file: MappedFile(url: url), verifyChecksum: verifyChecksum)
    }

    public init(data: Data, verifyChecksum: Bool = true) throws {
        try self.init(file: MappedFile(copying: data), verifyChecksum: verifyChecksum)
    }

    init(file: MappedFile, verifyChecksum: Bool) throws {
        let c = try Container(file: file, magic: "IBLX", verifyChecksum: verifyChecksum)
        let s = try c.section(1)
        let w = try c.section(2, recordSize: 8)
        let n = try c.section(3, recordSize: 12)
        let e = try c.section(4, recordSize: 8)
        guard n.count > 0 else { throw LexiconFormatError.badRecordSize(3) }
        self.file = file
        strings = s.offset
        words = w.offset
        nodes = n.offset
        edges = e.offset
        wordCount = w.count
        nodeCount = n.count
        checksum = c.checksum
    }

    // MARK: Trie

    public var root: TrieCursor { TrieCursor(node: 0) }

    /// Child reached by `label` (a Unicode scalar value), binary search over the node's sorted edges.
    @inline(__always)
    public func child(of cursor: TrieCursor, label: UInt32) -> TrieCursor? {
        let o = nodes + Int(cursor.node) * 12
        let start = Int(file.u32(o))
        var lo = 0
        var hi = Int(file.u16(o + 8)) - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let e = edges + (start + mid) * 8
            let l = file.u32(e)
            if l == label { return TrieCursor(node: file.u32(e + 4)) }
            if l < label { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// The word that ends exactly at `cursor`, if any.
    @inline(__always)
    public func wordID(at cursor: TrieCursor) -> WordID? {
        let id = file.u32(nodes + Int(cursor.node) * 12 + 4)
        return id == Self.noWord ? nil : id
    }

    @inline(__always)
    public func hasChildren(_ cursor: TrieCursor) -> Bool {
        file.u16(nodes + Int(cursor.node) * 12 + 8) != 0
    }

    /// Smallest quantized neg-log-probability of any word in the subtree (most probable completion).
    @inline(__always)
    public func bestQuantizedScore(under cursor: TrieCursor) -> UInt16 {
        file.u16(nodes + Int(cursor.node) * 12 + 10)
    }

    /// Natural log of the most probable word in the subtree, an optimistic bound for pruning.
    @inline(__always)
    public func bestLogProbability(under cursor: TrieCursor) -> Double {
        -Double(bestQuantizedScore(under: cursor)) / Self.quantScale
    }

    /// Cursor for `prefix`, or nil when no word starts with it.
    public func cursor(for prefix: String) -> TrieCursor? {
        var c = root
        for sc in prefix.unicodeScalars {
            guard let n = child(of: c, label: sc.value) else { return nil }
            c = n
        }
        return c
    }

    // MARK: Words

    /// Exact lookup. No allocation for native Swift strings.
    public func lookup(_ word: String) -> WordID? {
        guard let c = cursor(for: word) else { return nil }
        return wordID(at: c)
    }

    @inline(__always)
    public func quantizedScore(of id: WordID) -> UInt16 {
        file.u16(words + Int(id) * 8 + 6)
    }

    /// Unigram natural-log probability: `-q / 2048`, so no `exp`/`log` call.
    @inline(__always)
    public func logProbability(of id: WordID) -> Double {
        -Double(quantizedScore(of: id)) / Self.quantScale
    }

    /// Zero-copy access to the UTF-8 bytes of a word (valid only inside `body`).
    public func withUTF8<R>(of id: WordID, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        let o = words + Int(id) * 8
        let start = strings + Int(file.u32(o))
        let len = Int(file.u16(o + 4))
        return try body(UnsafeBufferPointer(start: (file.base + start).assumingMemoryBound(to: UInt8.self), count: len))
    }

    /// Allocates a `String`; use `withUTF8` on hot paths.
    public func word(of id: WordID) -> String {
        withUTF8(of: id) { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Completions

    /// Up to `limit` word ids under `cursor` (the cursor's own word included), most probable first (ties by word
    /// id). Best-first over the trie using each node's `maxQ` bound, so only about `limit` words' worth of
    /// nodes are visited. Results replace the contents of `out`; with reused `scratch` and `out` it allocates nothing.
    public func completions(
        of cursor: TrieCursor, limit: Int, scratch: inout CompletionScratch, into out: inout [WordID]
    ) {
        out.removeAll(keepingCapacity: true)
        guard limit > 0 else { return }
        scratch.heap.removeAll(keepingCapacity: true)
        // Entry = key(16) | word-flag(1) | value(32): smaller is better; nodes expand before words at equal key so
        // equal-score words come out in id order.
        heapPush(&scratch.heap, nodeEntry(cursor.node))
        while out.count < limit, let top = heapPop(&scratch.heap) {
            let value = UInt32(truncatingIfNeeded: top)
            if (top >> 32) & 1 == 1 {
                out.append(value)
                continue
            }
            let o = nodes + Int(value) * 12
            let w = file.u32(o + 4)
            if w != Self.noWord {
                heapPush(&scratch.heap, (UInt64(quantizedScore(of: w)) << 33) | (1 << 32) | UInt64(w))
            }
            let first = Int(file.u32(o))
            let count = Int(file.u16(o + 8))
            for i in 0..<count {
                heapPush(&scratch.heap, nodeEntry(file.u32(edges + (first + i) * 8 + 4)))
            }
        }
    }

    /// Convenience (allocates).
    public func completions(prefix: String, limit: Int) -> [WordID] {
        guard let c = cursor(for: prefix) else { return [] }
        var scratch = CompletionScratch()
        var out: [WordID] = []
        completions(of: c, limit: limit, scratch: &scratch, into: &out)
        return out
    }

    @inline(__always)
    private func nodeEntry(_ node: UInt32) -> UInt64 {
        let maxQ = file.u16(nodes + Int(node) * 12 + 10)
        return (UInt64(maxQ) << 33) | UInt64(node)
    }
}

// Min-heap on UInt64 keys.
@inline(__always)
private func heapPush(_ h: inout [UInt64], _ v: UInt64) {
    h.append(v)
    var i = h.count - 1
    while i > 0 {
        let p = (i - 1) >> 1
        if h[p] <= v { break }
        h[i] = h[p]
        i = p
    }
    h[i] = v
}

@inline(__always)
private func heapPop(_ h: inout [UInt64]) -> UInt64? {
    guard let last = h.popLast() else { return nil }
    if h.isEmpty { return last }
    let top = h[0]
    var i = 0
    let n = h.count
    while true {
        var c = 2 * i + 1
        if c >= n { break }
        if c + 1 < n, h[c + 1] < h[c] { c += 1 }
        if h[c] >= last { break }
        h[i] = h[c]
        i = c
    }
    h[i] = last
    return top
}
