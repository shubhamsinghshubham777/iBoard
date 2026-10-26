import Foundation

public struct LicenseEntry: Codable, Equatable, Sendable {
    public var id, kind, spdx, attribution: String
    public var url: String?
    public var version: String?
    public var sha256: String
}

public struct LicenseManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var sources: [LicenseEntry]
    public var shareAlike: Bool
    /// "CC-BY-SA-4.0" when any input is share-alike (D-29), otherwise nil (inputs' own terms apply).
    public var derivedOutputLicense: String?
}

public struct SizeReport: Codable, Equatable, Sendable {
    public struct FileSize: Codable, Equatable, Sendable { public var bytes: Int; public var sections: [String: Int] }
    public var words: Int
    public var trieNodes: Int
    public var bigrams: Int
    public var trigrams: Int
    public var droppedOutOfVocabularyNgrams: Int
    public var lexicon: FileSize
    public var languageModel: FileSize
    public var totalBytes: Int
    public var bytesPerWord: Double

    public var text: String {
        var s = "words: \(words)\ntrie nodes: \(trieNodes)\nbigrams: \(bigrams)\ntrigrams: \(trigrams)\n"
        s += "dropped OOV ngrams: \(droppedOutOfVocabularyNgrams)\n"
        s += "lexicon: \(lexicon.bytes) B  \(lexicon.sections.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))\n"
        s += "lm: \(languageModel.bytes) B  \(languageModel.sections.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))\n"
        s += "total: \(totalBytes) B  (\(String(format: "%.2f", bytesPerWord)) B/word, lexicon only)\n"
        return s
    }
}

public struct BuildResult: Sendable {
    public var lexicon: Data
    public var languageModel: Data
    public var licenses: LicenseManifest
    public var report: SizeReport
}

public func buildLicenseManifest(_ manifest: SourceManifest, hashes: [String: String]) -> LicenseManifest {
    let entries = manifest.sources.sorted { $0.id < $1.id }.map {
        LicenseEntry(id: $0.id, kind: $0.kind, spdx: $0.spdx, attribution: $0.attribution, url: $0.url, version: $0.version, sha256: hashes[$0.id] ?? "")
    }
    let sa = entries.contains { $0.spdx.uppercased().contains("-SA") }
    return LicenseManifest(formatVersion: 1, sources: entries, shareAlike: sa, derivedOutputLicense: sa ? "CC-BY-SA-4.0" : nil)
}

/// Pure, deterministic build: same corpus + options => identical bytes. No timestamps or machine state.
public func build(corpus: LoadedCorpus, manifest: SourceManifest, options: LMOptions = LMOptions()) throws -> BuildResult {
    guard !corpus.unigrams.isEmpty else { throw LexError.invalidInput("no unigrams") }
    let ranked = rankWords(corpus.unigrams)
    var ids: [String: UInt32] = [:]
    for (i, w) in ranked.enumerated() { ids[w.word] = UInt32(i) }
    let lex = buildLexicon(ranked: ranked)
    let lexC = try Container(data: Data(lex), magic: LexFormat.magicLexicon)
    let lm = buildLM(ngrams: corpus.ngrams, wordIds: ids, vocab: ranked.count, lexChecksum: lexC.checksum, options: options)
    let lmC = try Container(data: Data(lm.file), magic: LexFormat.magicLM)
    func sizes(_ c: Container, _ names: [UInt32: String]) -> SizeReport.FileSize {
        var d: [String: Int] = [:]
        for (id, s) in c.sections { d[names[id] ?? "section\(id)"] = s.length }
        return .init(bytes: c.data.count, sections: d)
    }
    let lexSizes = sizes(lexC, [1: "strings", 2: "words", 3: "nodes", 4: "edges"])
    let lmSizes = sizes(lmC, [1: "meta", 2: "unigramBackoff", 3: "bigrams", 4: "trigrams"])
    let report = SizeReport(
        words: ranked.count, trieNodes: try lexC.section(3).count, bigrams: lm.stats.bigrams, trigrams: lm.stats.trigrams,
        droppedOutOfVocabularyNgrams: lm.stats.droppedOOV, lexicon: lexSizes, languageModel: lmSizes,
        totalBytes: lexSizes.bytes + lmSizes.bytes, bytesPerWord: Double(lexSizes.bytes) / Double(ranked.count))
    return BuildResult(lexicon: Data(lex), languageModel: Data(lm.file),
                       licenses: buildLicenseManifest(manifest, hashes: corpus.sourceHashes), report: report)
}

public func jsonData<T: Encodable>(_ v: T) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try e.encode(v) + Data("\n".utf8)
}

/// Loads sources, builds, and writes lexicon.iblex, lm.iblm, licenses.json, size-report.json into `outDir`.
public func run(manifestURL: URL, outDir: URL, options: LMOptions) throws -> BuildResult {
    let manifest = try JSONDecoder().decode(SourceManifest.self, from: Data(contentsOf: manifestURL))
    let corpus = try loadCorpus(manifest: manifest, baseDir: manifestURL.deletingLastPathComponent())
    let result = try build(corpus: corpus, manifest: manifest, options: options)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try result.lexicon.write(to: outDir.appendingPathComponent("lexicon.iblex"))
    try result.languageModel.write(to: outDir.appendingPathComponent("lm.iblm"))
    try jsonData(result.licenses).write(to: outDir.appendingPathComponent("licenses.json"))
    try jsonData(result.report).write(to: outDir.appendingPathComponent("size-report.json"))
    return result
}
