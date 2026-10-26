import Foundation

// `.iboarddict` import / export core (F4, M3-07). Pure data in, pure data out; the app screens, file pickers and the
// hand-over to the keyboard (single writer, P-23) are somebody else's job.
//
// Format (version 1): UTF-8, JSON lines, one object per line, `\n` separated.
//   line 1   {"format":"iboarddict","version":1,"created":1700000000,"generator":"iBoard"}
//   word     {"t":"word","w":"shubham","s":"Shubham","c":3.2,"u":5,"f":["neverCorrect"]}
//   phrase   {"t":"phrase","w":["see","you","at"],"c":2,"u":3}
//   forget   {"t":"forget","w":"xyz","at":1700000000}
//   never    {"t":"never","w":"abc"}
// `w` lowercase; `s` optional display casing (must lowercase to `w`); `c` decayed weight at export time; `u` lifetime
// observation count. Unknown record types and unknown flags are ignored (forward compatible); a newer `version` is
// refused. Bigram / trigram counts are intentionally not exported (they are rebuilt from typing).

public enum DictionaryFormat {
    public static let identifier = "iboarddict"
    public static let version = 1
    public static let fileExtension = "iboarddict"
    public static let maxBytes = 8 * 1024 * 1024
    public static let maxLineBytes = 2048
    public static let maxRecords = 100_000
    public static let maxWeight = 1000.0
    public static let maxUses = 10_000
    public static let maxWordsPerKind = 10_000
    public static let maxPhrases = 1_000
    public static let maxListWords = 2_000
}

public enum DictionaryError: Error, Equatable {
    case empty, tooLarge, missingHeader, wrongFormat, unsupportedVersion(Int), tooManyRecords
}

public enum DictionaryRejection: String, Sendable, Hashable {
    case invalidUTF8, lineTooLong, malformedJSON, unknownRecordType, invalidField, invalidWord, invalidWeight
}

public struct DictionaryWord: Sendable, Equatable {
    public var word: String
    public var surface: String?
    public var weight: Double
    public var uses: Int
    public var neverCorrect: Bool
}

public struct DictionaryPhrase: Sendable, Equatable {
    public var words: [String]
    public var weight: Double
    public var uses: Int
}

public struct DictionaryForget: Sendable, Equatable {
    public var word: String
    public var at: Double
}

/// What decoding did, as counts only (never words).
public struct DictionaryDecodeReport: Sendable, Equatable {
    public var lines = 0
    public var accepted = 0
    public var rejected: [DictionaryRejection: Int] = [:]
    /// Valid records dropped because a per-kind cap was exceeded (lowest weights go first).
    public var droppedByCap = 0
    public var rejectedTotal: Int { rejected.values.reduce(0, +) }
}

/// A validated dictionary. Everything inside already passed the word filter and the limits.
public struct DecodedDictionary: Sendable, Equatable {
    public var created: Double
    public var generator: String?
    public var words: [DictionaryWord] = []
    public var phrases: [DictionaryPhrase] = []
    public var forgotten: [DictionaryForget] = []
    public var neverCorrect: [String] = []
    public var report = DictionaryDecodeReport()
}

// MARK: - Export

public enum DictionaryExporter {
    private struct Header: Encodable {
        var format = DictionaryFormat.identifier
        var version = DictionaryFormat.version
        var created: Double
        var generator = "iBoard"
    }
    private struct WordLine: Encodable {
        var t = "word"
        var w: String
        var s: String?
        var c: Double
        var u: Int
        var f: [String]?
    }
    private struct PhraseLine: Encodable {
        var t = "phrase"
        var w: [String]
        var c: Double
        var u: Int
    }
    private struct ForgetLine: Encodable {
        var t = "forget"
        var w: String
        var at: Double
    }
    private struct NeverLine: Encodable {
        var t = "never"
        var w: String
    }

    private static func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }

    /// Deterministic export of words (with casing, decayed weight, uses, never-correct flag), phrases, the forget list
    /// and never-correct words that are not in the word list. Entries decayed below `minKeepWeight` are left out.
    public static func export(state: PersonalModelState, at now: Double,
                              config: PersonalStoreConfig = PersonalStoreConfig()) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        func line<T: Encodable>(_ v: T) {
            if let d = try? enc.encode(v) { out.append(d); out.append(0x0A) }
        }
        line(Header(created: now.rounded()))
        var wordSet = Set<String>()
        for (w, e) in state.unigrams.sorted(by: { $0.key < $1.key }) {
            let c = state.effective(e, at: now)
            guard c >= config.minKeepWeight, state.forgotten[w] == nil else { continue }
            wordSet.insert(w)
            line(WordLine(w: w, s: state.surfaces[w], c: round4(c), u: Int(e.uses),
                          f: state.neverCorrect.contains(w) ? ["neverCorrect"] : nil))
        }
        for (k, e) in state.phrases.sorted(by: { $0.key < $1.key }) {
            let c = state.effective(e, at: now)
            guard c >= config.minKeepWeight else { continue }
            let words = k.split(separator: PersonalModelState.separator, omittingEmptySubsequences: false).map(String.init)
            guard (3...6).contains(words.count) else { continue }
            line(PhraseLine(w: words, c: round4(c), u: Int(e.uses)))
        }
        for (w, f) in state.forgotten.sorted(by: { $0.key < $1.key }) { line(ForgetLine(w: w, at: f.at.rounded())) }
        for w in state.neverCorrect.sorted() where !wordSet.contains(w) { line(NeverLine(w: w)) }
        return out
    }
}

// MARK: - Decode

public enum DictionaryDecoder {
    private struct Header: Decodable { var format: String?; var version: Int?; var created: Double?; var generator: String? }
    private struct Peek: Decodable { var t: String? }
    private struct WordRec: Decodable { var w: String; var s: String?; var c: Double; var u: Int?; var f: [String]? }
    private struct PhraseRec: Decodable { var w: [String]; var c: Double; var u: Int? }
    private struct ForgetRec: Decodable { var w: String; var at: Double? }
    private struct NeverRec: Decodable { var w: String }

    /// Loose validity for forget / never-correct entries (they may be short or unusual: "ok", "ai").
    static func isListWord(_ w: String) -> Bool {
        let n = w.count
        guard (1...LearnableWord.maxLength).contains(n) else { return false }
        return !w.unicodeScalars.contains { $0 == PersonalModelState.separator.unicodeScalars.first! || $0.properties.generalCategory == .control
            || $0.properties.isWhitespace || $0.properties.generalCategory == .format }
    }

    private static func validWeight(_ c: Double) -> Double? {
        guard c.isFinite, c > 0 else { return nil }
        return min(c, DictionaryFormat.maxWeight)
    }

    private static func validUses(_ u: Int?) -> Int {
        max(1, min(u ?? 1, DictionaryFormat.maxUses))
    }

    public static func decode(_ input: Data) throws -> DecodedDictionary {
        guard !input.isEmpty else { throw DictionaryError.empty }
        guard input.count <= DictionaryFormat.maxBytes else { throw DictionaryError.tooLarge }
        var data = input
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        let dec = JSONDecoder()
        let rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard rawLines.count <= DictionaryFormat.maxRecords + 1 else { throw DictionaryError.tooManyRecords }

        func trimmed(_ l: Data) -> Data { l.last == 0x0D ? l.dropLast() : l }

        // Header
        guard let first = rawLines.first else { throw DictionaryError.empty }
        let headerData = trimmed(first)
        guard headerData.count <= DictionaryFormat.maxLineBytes,
              let h = try? dec.decode(Header.self, from: headerData) else { throw DictionaryError.missingHeader }
        guard let format = h.format else { throw DictionaryError.missingHeader }
        guard format == DictionaryFormat.identifier else { throw DictionaryError.wrongFormat }
        guard let version = h.version, version >= 1 else { throw DictionaryError.missingHeader }
        guard version <= DictionaryFormat.version else { throw DictionaryError.unsupportedVersion(version) }

        var out = DecodedDictionary(created: (h.created?.isFinite == true) ? h.created! : 0,
                                    generator: h.generator.map { String($0.prefix(64)) })
        var words: [String: DictionaryWord] = [:]
        var phrases: [String: DictionaryPhrase] = [:]
        var forgets: [String: DictionaryForget] = [:]
        var never = Set<String>()
        var report = DictionaryDecodeReport()
        func reject(_ r: DictionaryRejection) { report.rejected[r, default: 0] += 1 }

        for raw in rawLines.dropFirst() {
            let l = trimmed(raw)
            if l.isEmpty { continue }
            report.lines += 1
            guard l.count <= DictionaryFormat.maxLineBytes else { reject(.lineTooLong); continue }
            guard String(data: l, encoding: .utf8) != nil else { reject(.invalidUTF8); continue }
            guard let peek = try? dec.decode(Peek.self, from: l), let type = peek.t else { reject(.malformedJSON); continue }
            switch type {
            case "word":
                guard let r = try? dec.decode(WordRec.self, from: l) else { reject(.invalidField); continue }
                let w = r.w.lowercased()
                guard LearnableWord.rejection(w) == nil else { reject(.invalidWord); continue }
                guard let c = validWeight(r.c) else { reject(.invalidWeight); continue }
                var surface: String?
                if let s = r.s {
                    if s.lowercased() != w { reject(.invalidField); continue }
                    if s != w { surface = s }
                }
                let never = r.f?.contains("neverCorrect") == true
                let rec = DictionaryWord(word: w, surface: surface, weight: c, uses: validUses(r.u), neverCorrect: never)
                if var old = words[w] {
                    old.weight = max(old.weight, rec.weight); old.uses = max(old.uses, rec.uses)
                    old.surface = old.surface ?? rec.surface; old.neverCorrect = old.neverCorrect || rec.neverCorrect
                    words[w] = old
                } else { words[w] = rec }
                report.accepted += 1
            case "phrase":
                guard let r = try? dec.decode(PhraseRec.self, from: l), (3...6).contains(r.w.count) else { reject(.invalidField); continue }
                let ws = r.w.map { $0.lowercased() }
                guard ws.allSatisfy({ LearnableWord.rejection($0) == nil }) else { reject(.invalidWord); continue }
                guard let c = validWeight(r.c) else { reject(.invalidWeight); continue }
                let key = PersonalModelState.key(ws)
                let rec = DictionaryPhrase(words: ws, weight: c, uses: validUses(r.u))
                if var old = phrases[key] { old.weight = max(old.weight, rec.weight); old.uses = max(old.uses, rec.uses); phrases[key] = old }
                else { phrases[key] = rec }
                report.accepted += 1
            case "forget":
                guard let r = try? dec.decode(ForgetRec.self, from: l) else { reject(.invalidField); continue }
                let w = r.w.lowercased()
                guard isListWord(w) else { reject(.invalidWord); continue }
                let at = (r.at?.isFinite == true) ? max(0, r.at!) : 0
                forgets[w] = DictionaryForget(word: w, at: max(at, forgets[w]?.at ?? 0))
                report.accepted += 1
            case "never":
                guard let r = try? dec.decode(NeverRec.self, from: l) else { reject(.invalidField); continue }
                let w = r.w.lowercased()
                guard isListWord(w) else { reject(.invalidWord); continue }
                never.insert(w)
                report.accepted += 1
            default:
                reject(.unknownRecordType)
            }
        }

        // Caps: keep the heaviest, deterministically.
        func capped<T>(_ items: [T], max cap: Int, weight: (T) -> Double, tie: (T) -> String) -> [T] {
            let sorted = items.sorted { weight($0) != weight($1) ? weight($0) > weight($1) : tie($0) < tie($1) }
            if sorted.count > cap { report.droppedByCap += sorted.count - cap }
            return Array(sorted.prefix(cap))
        }
        out.words = capped(Array(words.values), max: DictionaryFormat.maxWordsPerKind, weight: \.weight, tie: \.word)
        out.phrases = capped(Array(phrases.values), max: DictionaryFormat.maxPhrases, weight: \.weight,
                             tie: { PersonalModelState.key($0.words) })
        out.forgotten = Array(forgets.values.sorted { $0.at != $1.at ? $0.at > $1.at : $0.word < $1.word }
            .prefix(DictionaryFormat.maxListWords))
        out.neverCorrect = Array(never.sorted().prefix(DictionaryFormat.maxListWords))
        out.report = report
        return out
    }
}

// MARK: - Merge

public struct DictionaryImportOptions: Sendable, Equatable {
    /// Wipe the personal model first (the file becomes the whole model).
    public var replaceExisting = false
    public init(replaceExisting: Bool = false) { self.replaceExisting = replaceExisting }
}

/// Counts only.
public struct DictionaryImportReport: Sendable, Equatable {
    public var wordsAdded = 0
    public var wordsUpdated = 0
    public var wordsUnchanged = 0
    public var phrasesAdded = 0
    public var phrasesUpdated = 0
    public var phrasesUnchanged = 0
    /// Words / phrases skipped because the user (locally or in the file) forgot a word they contain.
    public var skippedForgotten = 0
    public var forgetsApplied = 0
    public var neverCorrectAdded = 0
}

public struct DictionaryImportPlan: Sendable, Equatable {
    public var ops: [PersonalOp]
    public var report: DictionaryImportReport
}

/// Merge rules (non-destructive by default; importing the same file twice changes nothing):
/// - Forget wins: a forget record removes the word and every n-gram/phrase containing it (local forgets are kept).
///   Words and phrases containing a locally forgotten word or a word forgotten in the file are not imported.
/// - Counts never add up: the merged weight is `max(local decayed weight, imported weight)` and `uses` is the max (saturating at 3), so
///   re-importing is idempotent and importing a backup cannot inflate counts. Casing: the local surface wins, else the
///   imported one.
/// - Never-correct: union (a word flag `neverCorrect` counts as a `never` record).
/// - `replaceExisting` clears the model first, then merges into the empty model.
public enum DictionaryMerger {
    public static func plan(_ dict: DecodedDictionary, into local: PersonalModelState, at now: Double,
                            options: DictionaryImportOptions = DictionaryImportOptions()) -> DictionaryImportPlan {
        var ops: [PersonalOp] = []
        var report = DictionaryImportReport()
        var state = local
        if options.replaceExisting { ops.append(.clear); state = PersonalModelState(halfLife: local.halfLife) }

        // Forgets first.
        var forgotten = Set(state.forgotten.keys)
        for f in dict.forgotten where state.forgotten[f.word] == nil {
            ops.append(.forget(word: f.word, at: min(f.at, now)))
            forgotten.insert(f.word)
            report.forgetsApplied += 1
        }

        // Splits one change into up to 3 add ops so `uses` follows (uses drives "learned" phrases).
        func adds(kind: PersonalNGramKind, key: String, surface: String?, weight: Double, uses: Int,
                  localEntry: PersonalEntry?) -> (ops: [PersonalOp], isNew: Bool) {
            let localW = localEntry.map { state.effective($0, at: now) } ?? 0
            // `uses` only matters up to 3 (learned phrase at 2, full weight schedule at 3), and is compared saturated so
            // that re-importing a file never counts again.
            let localU = min(3, Int(localEntry?.uses ?? 0))
            let inc = max(0, weight - localW)
            let useGap = max(0, min(3, uses) - localU)
            if inc < 1e-3, useGap == 0 { return ([], false) }
            let k = max(1, min(3, useGap))
            let each = Float(max(inc, 1e-3) / Double(k))
            var list: [PersonalOp] = []
            for i in 0..<k {
                list.append(.add(kind: kind, key: key, increment: each, surface: i == 0 ? surface : nil, at: now))
            }
            return (list, localEntry == nil)
        }

        for w in dict.words.sorted(by: { $0.word < $1.word }) {
            if forgotten.contains(w.word) { report.skippedForgotten += 1; continue }
            let local = state.unigrams[w.word]
            let surface = (state.surfaces[w.word] == nil) ? w.surface : nil
            let r = adds(kind: .unigram, key: w.word, surface: surface, weight: w.weight, uses: w.uses, localEntry: local)
            if r.ops.isEmpty { report.wordsUnchanged += 1 } else {
                ops += r.ops
                if r.isNew { report.wordsAdded += 1 } else { report.wordsUpdated += 1 }
            }
            if w.neverCorrect, !state.neverCorrect.contains(w.word) { ops.append(.addNeverCorrect(word: w.word)); report.neverCorrectAdded += 1 }
        }
        for p in dict.phrases.sorted(by: { PersonalModelState.key($0.words) < PersonalModelState.key($1.words) }) {
            if p.words.contains(where: { forgotten.contains($0) }) { report.skippedForgotten += 1; continue }
            let key = PersonalModelState.key(p.words)
            let r = adds(kind: .phrase, key: key, surface: nil, weight: p.weight, uses: p.uses, localEntry: state.phrases[key])
            if r.ops.isEmpty { report.phrasesUnchanged += 1 } else {
                ops += r.ops
                if r.isNew { report.phrasesAdded += 1 } else { report.phrasesUpdated += 1 }
            }
        }
        var seenNever = Set<String>()
        for w in dict.neverCorrect where !state.neverCorrect.contains(w) && seenNever.insert(w).inserted {
            if dict.words.contains(where: { $0.word == w && $0.neverCorrect }) { continue }   // already counted via the flag
            ops.append(.addNeverCorrect(word: w)); report.neverCorrectAdded += 1
        }
        return DictionaryImportPlan(ops: ops, report: report)
    }
}

extension PersonalStore {
    /// `.iboarddict` bytes of the current model.
    public func exportDictionary() -> Data {
        DictionaryExporter.export(state: exportState(), at: currentTime, config: config)
    }

    /// Validates `data` and merges it into the model in one journal transaction. Throws only for an unusable file
    /// (wrong format / version / size); bad lines are skipped and counted in the decode report.
    @discardableResult
    public func importDictionary(_ data: Data, options: DictionaryImportOptions = DictionaryImportOptions())
        throws -> (decode: DictionaryDecodeReport, merge: DictionaryImportReport) {
        let dict = try DictionaryDecoder.decode(data)
        let plan = DictionaryMerger.plan(dict, into: exportState(), at: currentTime, options: options)
        apply(ops: plan.ops)
        return (dict.report, plan.report)
    }
}
