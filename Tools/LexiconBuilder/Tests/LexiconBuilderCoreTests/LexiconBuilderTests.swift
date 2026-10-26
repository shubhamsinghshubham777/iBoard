import Testing
import Foundation
@testable import LexiconBuilderCore

private let unigramText = """
# synthetic fixture
the\t1000
hello\t300
help\t120
held\t40
héllo\t5
world\t250
नमस्ते\t60
"""

private let ngramText = """
hello world\t30
the world\t20
the help\t3
help the\t2
the hello world\t10
the the world\t1
a the world\t9
"""

private func fixture() throws -> (SourceManifest, LoadedCorpus) {
    let m = SourceManifest(sources: [
        SourceSpec(id: "syn-uni", path: "u.tsv", kind: "unigram", spdx: "CC0-1.0", attribution: "synthetic"),
        SourceSpec(id: "syn-ng", path: "n.tsv", kind: "ngram", spdx: "CC-BY-SA-4.0", attribution: "synthetic"),
    ])
    var c = LoadedCorpus()
    try parseUnigrams(unigramText, into: &c.unigrams)
    try parseNgrams(ngramText, into: &c.ngrams)
    c.sourceHashes = ["syn-uni": sha256Hex(Data(unigramText.utf8)), "syn-ng": sha256Hex(Data(ngramText.utf8))]
    return (m, c)
}

@Test func deterministicOutput() throws {
    let (m, c) = try fixture()
    let a = try build(corpus: c, manifest: m)
    // Rebuild from a differently ordered dictionary construction.
    var c2 = LoadedCorpus()
    try parseUnigrams(unigramText.split(separator: "\n").reversed().joined(separator: "\n"), into: &c2.unigrams)
    try parseNgrams(ngramText.split(separator: "\n").reversed().joined(separator: "\n"), into: &c2.ngrams)
    c2.sourceHashes = c.sourceHashes
    let b = try build(corpus: c2, manifest: m)
    #expect(a.lexicon == b.lexicon)
    #expect(a.languageModel == b.languageModel)
    #expect(try jsonData(a.licenses) == jsonData(b.licenses))
    #expect(try jsonData(a.report) == jsonData(b.report))
}

@Test func lexiconRoundTrip() throws {
    let (m, c) = try fixture()
    let r = try build(corpus: c, manifest: m)
    let lex = try LexiconReader(data: r.lexicon)
    #expect(lex.wordCount == 7)
    for (w, count) in c.unigrams {
        let id = try #require(lex.lookup(w))
        #expect(lex.word(id: id) == w)
        let expected = log(Double(count) / Double(c.unigrams.values.reduce(0, +)))
        #expect(abs(lex.logProb(id: id) - expected) < 1.0 / LexFormat.quantScale)
    }
    #expect(lex.lookup("hel") == nil)
    #expect(lex.lookup("zzz") == nil)
    #expect(lex.lookup("") == nil)
    // Prefix lookup, ranked by frequency.
    #expect(lex.completions(prefix: "hel").map(\.word) == ["hello", "help", "held"])
    #expect(lex.completions(prefix: "hel", limit: 2).map(\.word) == ["hello", "help"])
    #expect(lex.completions(prefix: "नम").map(\.word) == ["नमस्ते"])
    #expect(lex.completions(prefix: "q").isEmpty)
    // Normalization: decomposed input finds the precomposed entry.
    #expect(lex.lookup("he\u{0301}llo") != nil)
}

@Test func lmRoundTripAndScoring() throws {
    let (m, c) = try fixture()
    let r = try build(corpus: c, manifest: m, options: LMOptions(minCount: 2))
    let lex = try LexiconReader(data: r.lexicon)
    let lm = try LMReader(data: r.languageModel, lexicon: lex)
    let hello = try #require(lex.lookup("hello")), world = try #require(lex.lookup("world"))
    let the = try #require(lex.lookup("the")), held = try #require(lex.lookup("held"))
    // "a" is out of vocabulary, so "a the world" was dropped; "the the world" (count 1) was pruned.
    #expect(r.report.droppedOutOfVocabularyNgrams == 1)
    #expect(lm.trigramCount == 1)
    // Observed continuation outranks an unobserved one.
    #expect(lm.probability(world, given: hello) > lm.probability(held, given: hello))
    #expect(lm.probability(world, given: the, hello) > lm.probability(held, given: the, hello))
    // Probabilities are sane and sum to at most about 1 over the vocabulary.
    let total = (0..<UInt32(lex.wordCount)).reduce(0.0) { $0 + lm.probability($1, given: hello) }
    #expect(total > 0.9 && total < 1.1)
    // Pruned bigram falls back to the unigram path.
    let help = try #require(lex.lookup("help"))
    #expect(lm.probability(help, given: the) > 0)
}

@Test func headerIsValidatedAndAligned() throws {
    let (m, c) = try fixture()
    let r = try build(corpus: c, manifest: m)
    #expect(r.lexicon.count % 4 == 0 && r.languageModel.count % 4 == 0)
    #expect(Array(r.lexicon.prefix(4)) == Array("IBLX".utf8))
    #expect(Array(r.lexicon[8..<12]) == [4, 3, 2, 1])   // little-endian 0x01020304
    var bad = r.lexicon
    bad[bad.count - 1] ^= 0xFF
    #expect(throws: LexError.badChecksum) { try LexiconReader(data: bad) }
    #expect(throws: LexError.badMagic) { try LexiconReader(data: r.languageModel) }
}

@Test func licenseManifest() throws {
    let (m, c) = try fixture()
    let r = try build(corpus: c, manifest: m)
    #expect(r.licenses.shareAlike)
    #expect(r.licenses.derivedOutputLicense == "CC-BY-SA-4.0")
    #expect(r.licenses.sources.map(\.id) == ["syn-ng", "syn-uni"])
    #expect(r.licenses.sources.allSatisfy { $0.sha256.count == 64 })
}

@Test func sizeReportAndEndToEnd() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lexb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(unigramText.utf8).write(to: dir.appendingPathComponent("u.tsv"))
    try Data(ngramText.utf8).write(to: dir.appendingPathComponent("n.tsv"))
    let (m, _) = try fixture()
    try jsonData(m).write(to: dir.appendingPathComponent("sources.json"))
    let out1 = dir.appendingPathComponent("o1"), out2 = dir.appendingPathComponent("o2")
    let r = try run(manifestURL: dir.appendingPathComponent("sources.json"), outDir: out1, options: LMOptions())
    _ = try run(manifestURL: dir.appendingPathComponent("sources.json"), outDir: out2, options: LMOptions())
    for f in ["lexicon.iblex", "lm.iblm", "licenses.json", "size-report.json"] {
        #expect(try Data(contentsOf: out1.appendingPathComponent(f)) == Data(contentsOf: out2.appendingPathComponent(f)))
    }
    print(r.report.text)
    #expect(r.report.totalBytes == r.lexicon.count + r.languageModel.count)
    #expect(r.report.words == 7 && r.report.lexicon.sections["words"] == 56)
    #expect(r.report.bytesPerWord > 0)
}

@Test func rejectsMalformedInput() {
    var d: [String: UInt64] = [:]
    #expect(throws: LexError.self) { try parseUnigrams("word 5\n", into: &d) }
    var n: [[String]: UInt64] = [:]
    #expect(throws: LexError.self) { try parseNgrams("a b c d\t3\n", into: &n) }
}
