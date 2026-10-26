import Foundation

/// Word ranking: count descending, then word ascending (UTF-8 byte order). Word id = rank.
func rankWords(_ unigrams: [String: UInt64]) -> [(word: String, count: UInt64)] {
    unigrams.map { (word: $0.key, count: $0.value) }.sorted {
        $0.count != $1.count ? $0.count > $1.count : Array($0.word.utf8).lexicographicallyPrecedes(Array($1.word.utf8))
    }
}

private final class TrieNode {
    var children: [UInt32: TrieNode] = [:]
    var wordId: UInt32 = LexFormat.noWord
    var maxQ: UInt16 = UInt16.max   // best (smallest) quantized neg-log-prob in subtree
}

func buildLexicon(ranked: [(word: String, count: UInt64)]) -> [UInt8] {
    let total = Double(ranked.reduce(0) { $0 + $1.count })
    let root = TrieNode()
    var strings = ByteWriter(), words = ByteWriter()
    for (i, w) in ranked.enumerated() {
        let q = quantize(Double(w.count) / total)
        let utf8 = Array(w.word.utf8)
        words.u32(UInt32(strings.bytes.count)); words.u16(UInt16(utf8.count)); words.u16(q)
        strings.bytes.append(contentsOf: utf8)
        var n = root
        for sc in w.word.unicodeScalars {
            if let c = n.children[sc.value] { n = c } else { let c = TrieNode(); n.children[sc.value] = c; n = c }
        }
        n.wordId = UInt32(i)
        n.maxQ = q
    }
    func fill(_ n: TrieNode) -> UInt16 {
        var best = n.maxQ
        for c in n.children.values { best = min(best, fill(c)) }
        n.maxQ = best
        return best
    }
    _ = fill(root)
    // BFS: node indices; each node's edges are contiguous and sorted by label.
    var order: [TrieNode] = [root]
    var idx = 0
    var nodesW = ByteWriter(), edgesW = ByteWriter()
    var edgeCount: UInt32 = 0
    while idx < order.count {
        let n = order[idx]; idx += 1
        let kids = n.children.sorted { $0.key < $1.key }
        nodesW.u32(edgeCount); nodesW.u32(n.wordId); nodesW.u16(UInt16(kids.count)); nodesW.u16(n.maxQ)
        for (label, child) in kids {
            order.append(child)
            edgesW.u32(label); edgesW.u32(UInt32(order.count - 1))
            edgeCount += 1
        }
    }
    strings.align4()
    return assembleContainer(magic: LexFormat.magicLexicon, sections: [
        SectionData(id: LexFormat.LexSection.strings.rawValue, count: UInt32(strings.bytes.count), bytes: strings.bytes),
        SectionData(id: LexFormat.LexSection.words.rawValue, count: UInt32(ranked.count), bytes: words.bytes),
        SectionData(id: LexFormat.LexSection.nodes.rawValue, count: UInt32(order.count), bytes: nodesW.bytes),
        SectionData(id: LexFormat.LexSection.edges.rawValue, count: edgeCount, bytes: edgesW.bytes),
    ])
}
