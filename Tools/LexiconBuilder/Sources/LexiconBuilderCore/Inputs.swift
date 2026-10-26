import Foundation
import CryptoKit

public struct SourceSpec: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var kind: String          // "unigram" | "ngram"
    public var spdx: String
    public var attribution: String
    public var url: String?
    public var version: String?
    public init(id: String, path: String, kind: String, spdx: String, attribution: String, url: String? = nil, version: String? = nil) {
        self.id = id; self.path = path; self.kind = kind; self.spdx = spdx
        self.attribution = attribution; self.url = url; self.version = version
    }
}

public struct SourceManifest: Codable, Sendable {
    public var sources: [SourceSpec]
    public init(sources: [SourceSpec]) { self.sources = sources }
}

public struct LoadedCorpus: Sendable {
    public var unigrams: [String: UInt64] = [:]
    public var ngrams: [[String]: UInt64] = [:]   // keys of length 2 or 3
    public var sourceHashes: [String: String] = [:]
}

func normalize(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

func parseUnigrams(_ text: String, into dict: inout [String: UInt64]) throws {
    for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
        if line.hasPrefix("#") { continue }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2, let c = UInt64(parts[1].trimmingCharacters(in: .whitespaces)), c > 0, !parts[0].isEmpty else {
            throw LexError.invalidInput("unigram line \(i + 1): expected word<TAB>count")
        }
        dict[normalize(String(parts[0])), default: 0] += c
    }
}

func parseNgrams(_ text: String, into dict: inout [[String]: UInt64]) throws {
    for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
        if line.hasPrefix("#") { continue }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2, let c = UInt64(parts[1].trimmingCharacters(in: .whitespaces)), c > 0 else {
            throw LexError.invalidInput("ngram line \(i + 1): expected w1 w2 [w3]<TAB>count")
        }
        let words = parts[0].split(separator: " ").map { normalize(String($0)) }
        guard words.count == 2 || words.count == 3 else { throw LexError.invalidInput("ngram line \(i + 1): order must be 2 or 3") }
        dict[words, default: 0] += c
    }
}

public func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Loads all sources listed in a manifest (paths relative to `baseDir`).
public func loadCorpus(manifest: SourceManifest, baseDir: URL) throws -> LoadedCorpus {
    var corpus = LoadedCorpus()
    for s in manifest.sources.sorted(by: { $0.id < $1.id }) {
        let url = URL(fileURLWithPath: s.path, relativeTo: baseDir)
        let data = try Data(contentsOf: url)
        corpus.sourceHashes[s.id] = sha256Hex(data)
        guard let text = String(data: data, encoding: .utf8) else { throw LexError.invalidInput("\(s.id): not UTF-8") }
        switch s.kind {
        case "unigram": try parseUnigrams(text, into: &corpus.unigrams)
        case "ngram": try parseNgrams(text, into: &corpus.ngrams)
        default: throw LexError.invalidInput("\(s.id): unknown kind \(s.kind)")
        }
    }
    return corpus
}
