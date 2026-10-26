import Foundation

/// One decayed count. `weight` is the value at `stamp`; the effective weight at time `t` is
/// `weight * 0.5^((t - stamp) / halfLife)`. `uses` is the lifetime (undecayed) number of observations.
public struct PersonalEntry: Sendable, Equatable {
    public var weight: Float
    public var stamp: Double
    public var uses: UInt16
}

public enum PersonalNGramKind: UInt8, Sendable {
    case unigram = 1, bigram = 2, trigram = 3, phrase = 4
}

/// A word the user asked to forget (also used as a suppress list for base-lexicon suggestions).
public struct ForgetEntry: Sendable, Equatable {
    public var at: Double
    /// Deliberate retypes since `at` (used by the "typed deliberately 3x" rule in the policy).
    public var deliberate: UInt8
}

/// One mutation. The same value is applied to memory and appended to the journal, so replay equals live state.
public enum PersonalOp: Sendable, Equatable {
    case add(kind: PersonalNGramKind, key: String, increment: Float, surface: String?, at: Double)
    case forget(word: String, at: Double)
    case unforget(word: String)
    case bumpForgotten(word: String)
    case addNeverCorrect(word: String)
    case removeNeverCorrect(word: String)
    case clear
}

public struct PersonalStoreConfig: Sendable {
    public var halfLifeDays: Double = 60
    public var maxUnigrams = 10_000
    public var maxBigrams = 20_000
    public var maxTrigrams = 20_000
    public var maxPhrases = 1_000
    public var maxForgotten = 2_000
    public var maxNeverCorrect = 2_000
    /// Entries whose effective weight decayed below this are dropped at the next prune.
    public var minKeepWeight = 0.02
    /// Compact (snapshot + journal reset) after this many journal records or bytes.
    public var journalMaxRecords = 400
    public var journalMaxBytes = 128 * 1024
    public init() {}
}

/// The in-memory personal model: decayed unigram/bigram/trigram counts, phrase table, forget and never-correct lists.
/// Value type: handing a copy to a reader is O(1) until the next write (then one dictionary copy).
/// All words are stored lowercased; `surfaces` remembers casing only where it matters (proper nouns, "iPhone").
public struct PersonalModelState: Sendable {
    /// Key separator for multi-word keys (U+001F, cannot appear in a word).
    public static let separator: Character = "\u{1F}"

    public var unigrams: [String: PersonalEntry] = [:]
    public var bigrams: [String: PersonalEntry] = [:]
    public var trigrams: [String: PersonalEntry] = [:]
    public var phrases: [String: PersonalEntry] = [:]
    public var surfaces: [String: String] = [:]
    public var forgotten: [String: ForgetEntry] = [:]
    public var neverCorrect: Set<String> = []
    public var halfLife: Double

    public static let defaultHalfLife: Double = 60 * 86_400

    public init(halfLife: Double = PersonalModelState.defaultHalfLife) { self.halfLife = halfLife }

    public static func key(_ words: [String]) -> String { words.joined(separator: String(separator)) }

    public func effective(_ e: PersonalEntry, at now: Double) -> Double {
        let dt = max(0, now - e.stamp)
        return Double(e.weight) * pow(0.5, dt / halfLife)
    }

    public func entry(_ kind: PersonalNGramKind, _ key: String) -> PersonalEntry? {
        switch kind {
        case .unigram: unigrams[key]
        case .bigram: bigrams[key]
        case .trigram: trigrams[key]
        case .phrase: phrases[key]
        }
    }

    public func effectiveWeight(_ kind: PersonalNGramKind, _ key: String, at now: Double) -> Double {
        entry(kind, key).map { effective($0, at: now) } ?? 0
    }

    /// Total effective unigram mass.
    public func totalUnigramMass(at now: Double) -> Double {
        unigrams.values.reduce(0) { $0 + effective($1, at: now) }
    }

    public mutating func apply(_ op: PersonalOp) {
        switch op {
        case let .add(kind, key, inc, surface, at):
            let cur = entry(kind, key)
            let base = cur.map { Float(effective($0, at: at)) } ?? 0
            let uses = min(UInt16.max, (cur?.uses ?? 0) &+ 1)
            let new = PersonalEntry(weight: base + inc, stamp: at, uses: uses)
            switch kind {
            case .unigram:
                unigrams[key] = new
                if let surface { surfaces[key] = surface }
            case .bigram: bigrams[key] = new
            case .trigram: trigrams[key] = new
            case .phrase: phrases[key] = new
            }
        case let .forget(word, at):
            removeWord(word)
            forgotten[word] = ForgetEntry(at: at, deliberate: 0)
        case let .unforget(word):
            forgotten[word] = nil
        case let .bumpForgotten(word):
            if var f = forgotten[word] { f.deliberate = min(255, f.deliberate + 1); forgotten[word] = f }
        case let .addNeverCorrect(word): neverCorrect.insert(word)
        case let .removeNeverCorrect(word): neverCorrect.remove(word)
        case .clear:
            unigrams = [:]; bigrams = [:]; trigrams = [:]; phrases = [:]
            surfaces = [:]; forgotten = [:]; neverCorrect = []
        }
    }

    /// Removes the word and every n-gram / phrase that contains it.
    mutating func removeWord(_ word: String) {
        unigrams[word] = nil
        surfaces[word] = nil
        let sep = Self.separator
        func contains(_ k: String) -> Bool {
            k.split(separator: sep, omittingEmptySubsequences: false).contains { $0 == word[...] }
        }
        bigrams = bigrams.filter { !contains($0.key) }
        trigrams = trigrams.filter { !contains($0.key) }
        phrases = phrases.filter { !contains($0.key) }
    }

    /// Rough resident size: key bytes plus per-entry overhead (dictionary slot, String header, entry). An estimate for
    /// budgeting (P-21), not a measurement.
    public var estimatedMemoryBytes: Int {
        func size(_ d: [String: PersonalEntry]) -> Int { d.reduce(0) { $0 + $1.key.utf8.count + 64 } }
        return size(unigrams) + size(bigrams) + size(trigrams) + size(phrases)
            + surfaces.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 64 }
            + forgotten.reduce(0) { $0 + $1.key.utf8.count + 48 }
            + neverCorrect.reduce(0) { $0 + $1.utf8.count + 40 }
    }

    /// Drops entries below `minKeepWeight` and evicts the lowest effective weight until each table is within its cap
    /// (pruning to 90 % of the cap so eviction is amortised). Returns true when anything was removed.
    @discardableResult
    public mutating func prune(config: PersonalStoreConfig, at now: Double) -> Bool {
        var any = false
        let hl = halfLife
        func eff(_ e: PersonalEntry) -> Double { Double(e.weight) * pow(0.5, max(0, now - e.stamp) / hl) }
        func pruneTable(_ d: inout [String: PersonalEntry], cap: Int) -> [String] {
            var removed: [String] = []
            for (k, e) in d where eff(e) < config.minKeepWeight { removed.append(k) }
            for k in removed { d[k] = nil }
            if d.count > cap {
                let target = cap * 9 / 10
                let ranked = d.map { ($0.key, eff($0.value)) }.sorted { $0.1 < $1.1 }
                for (k, _) in ranked.prefix(d.count - target) { d[k] = nil; removed.append(k) }
            }
            return removed
        }
        let gone = pruneTable(&unigrams, cap: config.maxUnigrams)
        for k in gone { surfaces[k] = nil }
        any = !gone.isEmpty
        any = !pruneTable(&bigrams, cap: config.maxBigrams).isEmpty || any
        any = !pruneTable(&trigrams, cap: config.maxTrigrams).isEmpty || any
        any = !pruneTable(&phrases, cap: config.maxPhrases).isEmpty || any
        if forgotten.count > config.maxForgotten {
            for k in forgotten.sorted(by: { $0.value.at < $1.value.at }).prefix(forgotten.count - config.maxForgotten) {
                forgotten[k.key] = nil
            }
            any = true
        }
        if neverCorrect.count > config.maxNeverCorrect {
            for k in neverCorrect.sorted().prefix(neverCorrect.count - config.maxNeverCorrect) { neverCorrect.remove(k) }
            any = true
        }
        return any
    }
}
