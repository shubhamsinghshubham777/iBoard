import Foundation
import Testing
import IBoardEngine

private struct Golden: Decodable {
    struct Word: Decodable { let id: Int; let w: String; let q: Int }
    struct Bi: Decodable { let a: Int; let b: Int; let p: Double }
    struct Tri: Decodable { let a: Int; let b: Int; let c: Int; let p: Double }
    let wordCount: Int
    let checksum: Int
    let bigramCount: Int
    let trigramCount: Int
    let words: [Word]
    let completions: [String: [Int]]
    let bigramProbs: [Bi]
    let trigramProbs: [Tri]
}

private func golden() throws -> Golden {
    try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Fixture.small.url("golden", "json")))
}

@Suite struct LexiconReaderTests {
    @Test func opensAndMatchesReferenceReaderWords() throws {
        let g = try golden()
        let lex = try Fixture.small.lexicon()
        #expect(lex.wordCount == g.wordCount)
        #expect(Int(lex.checksum) == g.checksum)
        for w in g.words {
            let id = UInt32(w.id)
            #expect(lex.word(of: id) == w.w)
            #expect(Int(lex.quantizedScore(of: id)) == w.q)
            #expect(lex.lookup(w.w) == id)
            #expect(lex.withUTF8(of: id) { Array($0) } == Array(w.w.utf8))
        }
    }

    @Test func unigramMatchesCountsFromInputs() throws {
        let lex = try Fixture.small.lexicon()
        let text = try String(contentsOf: Fixture.small.url("uni", "tsv"), encoding: .utf8)
        var counts: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            counts[String(parts[0])] = Double(parts[1])!
        }
        let total = counts.values.reduce(0, +)
        for (w, c) in counts {
            let id = try #require(lex.lookup(w))
            let expected = log(c / total)
            #expect(abs(lex.logProbability(of: id) - expected) < 1.0 / 2048 + 1e-9, "\(w)")
        }
        // Rank order: ids ascend with decreasing count.
        #expect(lex.word(of: 0) == "the")
    }

    @Test func missesAreNil() throws {
        let lex = try Fixture.small.lexicon()
        for w in ["", "zzz", "thex", "th", "helloo", "THE"] { #expect(lex.lookup(w) == nil, "\(w)") }
        #expect(lex.cursor(for: "zz") == nil)
    }

    @Test func prefixCompletionsMatchReference() throws {
        let g = try golden()
        let lex = try Fixture.small.lexicon()
        for (prefix, ids) in g.completions {
            #expect(lex.completions(prefix: prefix, limit: Int.max).map(Int.init) == ids, "prefix '\(prefix)'")
            // top-k is a prefix of the full ranking
            #expect(lex.completions(prefix: prefix, limit: 5).map(Int.init) == Array(ids.prefix(5)), "top5 '\(prefix)'")
        }
    }

    @Test func completionsReuseScratch() throws {
        let lex = try Fixture.small.lexicon()
        var scratch = CompletionScratch()
        var out: [UInt32] = []
        out.reserveCapacity(16)
        let c = try #require(lex.cursor(for: "th"))
        lex.completions(of: c, limit: 4, scratch: &scratch, into: &out)
        let first = out
        lex.completions(of: lex.root, limit: 3, scratch: &scratch, into: &out)
        #expect(out.count == 3)
        lex.completions(of: c, limit: 4, scratch: &scratch, into: &out)
        #expect(out == first)
        #expect(Set(first.map { lex.word(of: $0) }).isSubset(of: Set(["the", "that", "this", "they", "them", "then", "there", "their", "these", "thanks", "think", "thinking", "thank"])))
    }

    @Test func trieCursorWalk() throws {
        let lex = try Fixture.small.lexicon()
        var c = lex.root
        for sc in "hello".unicodeScalars { c = try #require(lex.child(of: c, label: sc.value)) }
        #expect(lex.wordID(at: c) == lex.lookup("hello"))
        #expect(lex.child(of: c, label: UInt32(UInt8(ascii: "q"))) == nil)
        let h = try #require(lex.cursor(for: "hel"))
        #expect(lex.wordID(at: h) == nil)
        #expect(lex.hasChildren(h))
        #expect(lex.bestQuantizedScore(under: h) <= lex.quantizedScore(of: try #require(lex.lookup("hello"))))
    }

    @Test func dataAndURLInitsAgree() throws {
        let data = try Data(contentsOf: Fixture.small.url("lexicon", "iblex"))
        let a = try Lexicon(data: data)
        let b = try Fixture.small.lexicon()
        #expect(a.checksum == b.checksum)
        #expect(a.lookup("world") == b.lookup("world"))
    }

    @Test func rejectsCorruptFiles() throws {
        let good = try Data(contentsOf: Fixture.small.url("lexicon", "iblex"))
        func expect(_ data: Data, _ err: LexiconFormatError, verify: Bool = true, _ line: Int = #line) {
            do {
                _ = try Lexicon(data: data, verifyChecksum: verify)
                Issue.record("expected \(err) (line \(line))")
            } catch let e as LexiconFormatError { #expect(e == err, "line \(line)") } catch { Issue.record("\(error)") }
        }
        var bad = good; bad[0] = UInt8(ascii: "X")
        expect(bad, .badMagic)
        bad = good; bad[4] = 2
        expect(bad, .unsupportedVersion(2))
        bad = good; bad[8] = 0
        expect(bad, .badEndianMarker)
        expect(good.prefix(good.count - 4), .sizeMismatch)
        expect(good.prefix(10), .truncated)
        bad = good; bad[good.count - 1] ^= 0xFF
        expect(bad, .checksumMismatch)
        // Skipping the checksum scan accepts the flipped byte (it is padding or data), proving the flag is honoured.
        #expect((try? Lexicon(data: bad, verifyChecksum: false)) != nil)
        // An LM file is not a lexicon.
        expect(try Data(contentsOf: Fixture.small.url("lm", "iblm")), .badMagic)
    }

    @Test func rejectsMismatchedLM() throws {
        let smallLex = try Fixture.small.lexicon()
        let benchLM = try Data(contentsOf: Fixture.bench.url("lm", "iblm"))
        #expect(throws: LexiconFormatError.lexiconMismatch) { _ = try NGramModel(data: benchLM, lexicon: smallLex) }
        #expect(throws: LexiconFormatError.self) {
            _ = try NGramModel(data: try Data(contentsOf: Fixture.small.url("lexicon", "iblex")), lexicon: smallLex)
        }
    }
}

@Suite struct NGramModelTests {
    @Test func matchesReferenceReader() throws {
        let g = try golden()
        let lex = try Fixture.small.lexicon()
        let lm = try Fixture.small.model(lexicon: lex)
        #expect(lm.bigramCount == g.bigramCount)
        #expect(lm.trigramCount == g.trigramCount)
        for b in g.bigramProbs {
            let p = lm.bigramProbability(UInt32(b.b), after: UInt32(b.a))
            #expect(abs(p - b.p) <= 1e-12 * max(1, b.p), "bigram \(b.a) \(b.b)")
        }
        for t in g.trigramProbs {
            let p = lm.trigramProbability(UInt32(t.c), after: UInt32(t.a), UInt32(t.b))
            #expect(abs(p - t.p) <= 1e-12 * max(1, t.p), "trigram \(t.a) \(t.b) \(t.c)")
        }
    }

    @Test func contextBackoff() throws {
        let lex = try Fixture.small.lexicon()
        let lm = try Fixture.small.model(lexicon: lex)
        func id(_ s: String) -> UInt32 { lex.lookup(s)! }
        // No context is the unigram.
        #expect(lm.probability(id("the"), context: .none) == lm.unigramProbability(id("the")))
        // Seen continuation beats its unigram; unseen one stays at or below it.
        let ctx = LMContext(older: id("i"), recent: id("am"))
        #expect(lm.probability(id("going"), context: ctx) > lm.unigramProbability(id("going")) * 10)
        #expect(lm.probability(id("going"), context: LMContext(recent: id("am"))) > lm.unigramProbability(id("going")) * 10)
        #expect(lm.probability(id("school"), context: ctx) < lm.probability(id("going"), context: ctx))
        // log wrapper
        #expect(abs(lm.logProbability(id("going"), context: ctx) - log(lm.probability(id("going"), context: ctx))) < 1e-12)
        // Trigram with unseen (older, recent) pair falls back to the bigram.
        let unseen = LMContext(older: id("school"), recent: id("am"))
        #expect(lm.probability(id("going"), context: unseen) == lm.probability(id("going"), context: LMContext(recent: id("am"))))
    }
}
