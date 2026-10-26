import Foundation

public struct PersonalRecoveryReport: Sendable, Equatable {
    public var readFailed = false
    public var snapshotCorrupt = false
    public var corruptJournalLines = 0
    public var tornJournalTail = false
    public var replayedRecords = 0
    public var isClean: Bool { !readFailed && !snapshotCorrupt && corruptJournalLines == 0 && !tornJournalTail }
}

public struct PersonalStoreStats: Sendable, Equatable {
    public var unigrams: Int
    public var bigrams: Int
    public var trigrams: Int
    public var phrases: Int
    public var forgotten: Int
    public var neverCorrect: Int
    public var estimatedMemoryBytes: Int
    public var journalRecords: Int
}

/// The on-device personal model. Single writer (the keyboard extension).
///
/// Persistence design (P-16): every mutation is applied in memory and appended to the journal in one short file
/// operation; the journal is folded into an atomically written snapshot once it grows. Nothing is held open between
/// calls, and no store method suspends, so no file work can straddle a suspension point. A crash can lose at most the
/// last torn append; a corrupt snapshot or journal line is skipped and reported, never fatal.
///
/// Writes that fail (e.g. App Group without Full Access) keep the in-memory state and set `lastStorageErrorCount`;
/// they never throw into the typing path.
public actor PersonalStore {
    public let config: PersonalStoreConfig
    public nonisolated let storageMode: PersonalStorageMode
    private let storage: any PersonalStorage
    private let clock: any PersonalClock
    private var state: PersonalModelState
    private var seq: UInt64
    private var journalRecords = 0
    private var journalBytes = 0
    private var persistenceEnabled = true
    private var cachedScorer: PersonalScorer?
    public private(set) var recovery: PersonalRecoveryReport
    public private(set) var storageErrorCount = 0

    /// Loads synchronously (two small file reads). Never throws: problems are reported in `recovery`.
    public init(storage: any PersonalStorage, clock: any PersonalClock = SystemPersonalClock(),
                config: PersonalStoreConfig = PersonalStoreConfig()) {
        self.storage = storage
        self.storageMode = storage.mode
        self.clock = clock
        self.config = config
        let loaded = PersonalStore.loadOrEmpty(storage: storage, config: config)
        var state = loaded.state
        state.halfLife = config.halfLifeDays * 86_400
        var records = loaded.journalRecords
        var bytes = loaded.journalBytes
        var errors = 0
        let enabled = !loaded.report.readFailed
        if enabled, !loaded.report.isClean {
            // Rewrite a clean snapshot so a torn/corrupt tail cannot poison the next append.
            state.prune(config: config, at: clock.now())
            do {
                try storage.writeSnapshot(PersonalSnapshotCodec.encode(state, lastSeq: loaded.lastSeq))
                try storage.resetJournal()
                records = 0; bytes = 0
            } catch { errors += 1 }
        }
        self.state = state
        self.seq = loaded.lastSeq
        self.recovery = loaded.report
        self.journalRecords = records
        self.journalBytes = bytes
        self.persistenceEnabled = enabled
        self.storageErrorCount = errors
    }

    // MARK: Loading

    struct Loaded {
        var state: PersonalModelState
        var lastSeq: UInt64
        var report: PersonalRecoveryReport
        var hadData: Bool
        var journalRecords: Int
        var journalBytes: Int
    }

    static func load(storage: any PersonalStorage, config: PersonalStoreConfig) throws -> Loaded {
        let loaded = loadOrEmpty(storage: storage, config: config)
        if loaded.report.readFailed { throw PersonalCodecError.truncated }
        return loaded
    }

    static func loadOrEmpty(storage: any PersonalStorage, config: PersonalStoreConfig) -> Loaded {
        var report = PersonalRecoveryReport()
        var state = PersonalModelState(halfLife: config.halfLifeDays * 86_400)
        var lastSeq: UInt64 = 0
        var hadData = false
        var journal = Data()
        do {
            if let snap = try storage.readSnapshot() {
                hadData = true
                do {
                    let decoded = try PersonalSnapshotCodec.decode(snap)
                    state = decoded.state
                    lastSeq = decoded.lastSeq
                } catch {
                    report.snapshotCorrupt = true
                }
            }
            journal = try storage.readJournal()
        } catch {
            report.readFailed = true
            return Loaded(state: state, lastSeq: 0, report: report, hadData: false, journalRecords: 0, journalBytes: 0)
        }
        let replay = PersonalJournalCodec.replay(journal)
        report.corruptJournalLines = replay.corruptLines
        report.tornJournalTail = replay.tornTail
        let snapshotSeq = lastSeq
        var applied = 0
        for (s, op) in replay.records {
            lastSeq = max(lastSeq, s)
            if s > snapshotSeq { state.apply(op); applied += 1 }
        }
        report.replayedRecords = applied
        if !journal.isEmpty { hadData = true }
        return Loaded(state: state, lastSeq: lastSeq, report: report, hadData: hadData,
                      journalRecords: replay.records.count, journalBytes: journal.count)
    }

    // MARK: Normalisation

    public nonisolated static func normalize(_ word: String) -> String { word.lowercased() }

    // MARK: Learning

    /// Counts `word` (unigram) and, given preceding words, its bigram and trigram. One journal transaction.
    /// `surface` is kept only when it differs from the lowercased form (proper nouns, "iPhone").
    /// `phraseContext` (up to 5 preceding words in the same sentence) also records the 3-6 word phrases ending at
    /// `word` (increment 1 each), in the same journal transaction.
    public func learn(word: String, surface: String? = nil, context: [String] = [], increment: Float,
                      phraseContext: [String] = []) {
        let w = Self.normalize(word)
        guard !w.isEmpty, increment > 0 else { return }
        let now = clock.now()
        let keptSurface = surface.flatMap { $0 == w ? nil : $0 }
        var ops: [PersonalOp] = [.add(kind: .unigram, key: w, increment: increment, surface: keptSurface, at: now)]
        let ctx = context.suffix(2).map(Self.normalize)
        if let a = ctx.last {
            ops.append(.add(kind: .bigram, key: PersonalModelState.key([a, w]), increment: increment, surface: nil, at: now))
            if ctx.count == 2 {
                ops.append(.add(kind: .trigram, key: PersonalModelState.key([ctx[0], a, w]), increment: increment,
                                surface: nil, at: now))
            }
        }
        let chain = phraseContext.suffix(5).map(Self.normalize)
        if chain.count >= 2 {
            for n in 2...chain.count {
                ops.append(.add(kind: .phrase, key: PersonalModelState.key(Array(chain.suffix(n)) + [w]), increment: 1,
                                surface: nil, at: now))
            }
        }
        commit(ops)
    }

    /// Counts a 3-6 word sequence in the phrase table. Phrases seen once are candidates; the scorer and
    /// `repeatedPhrases` treat entries with `uses >= 2` as learned.
    public func learnPhrase(_ words: [String], increment: Float = 1) {
        guard (3...6).contains(words.count), increment > 0 else { return }
        commit([.add(kind: .phrase, key: PersonalModelState.key(words.map(Self.normalize)), increment: increment,
                     surface: nil, at: clock.now())])
    }

    // MARK: Forget / never-correct

    /// Removes the word and every n-gram/phrase containing it, and records it on the forget list.
    public func forget(_ word: String) {
        let w = Self.normalize(word)
        guard !w.isEmpty else { return }
        commit([.forget(word: w, at: clock.now())])
    }

    public func unforget(_ word: String) { commit([.unforget(word: Self.normalize(word))]) }
    public func noteDeliberateRetypeOfForgotten(_ word: String) { commit([.bumpForgotten(word: Self.normalize(word))]) }
    public func addNeverCorrect(_ word: String) { commit([.addNeverCorrect(word: Self.normalize(word))]) }
    public func removeNeverCorrect(_ word: String) { commit([.removeNeverCorrect(word: Self.normalize(word))]) }

    public func forgetEntry(for word: String) -> ForgetEntry? { state.forgotten[Self.normalize(word)] }
    public func isForgotten(_ word: String) -> Bool { state.forgotten[Self.normalize(word)] != nil }
    public func isNeverCorrect(_ word: String) -> Bool { state.neverCorrect.contains(Self.normalize(word)) }
    public func neverCorrectWords() -> [String] { state.neverCorrect.sorted() }
    public func forgottenWords() -> [String] { state.forgotten.keys.sorted() }

    /// Lifetime number of observations of `word` (0 when unknown).
    public func uses(of word: String) -> Int { Int(state.unigrams[Self.normalize(word)]?.uses ?? 0) }
    public func effectiveWeight(of word: String) -> Double {
        state.effectiveWeight(.unigram, Self.normalize(word), at: clock.now())
    }

    /// Phrases (word arrays) observed at least `minUses` times, most weighted first.
    public func repeatedPhrases(minUses: Int = 2, limit: Int = 50) -> [[String]] {
        let now = clock.now()
        return state.phrases.filter { Int($0.value.uses) >= minUses }
            .sorted { state.effective($0.value, at: now) > state.effective($1.value, at: now) }
            .prefix(limit)
            .map { $0.key.split(separator: PersonalModelState.separator).map(String.init) }
    }

    // MARK: Reading

    /// An immutable scoring view as of now. Cached until the next write; cheap to hold briefly (a long-held view
    /// makes the next write copy the tables once).
    public func scorer() -> PersonalScorer {
        if let c = cachedScorer { return c }
        let s = PersonalScorer(state: state, asOf: clock.now())
        cachedScorer = s
        return s
    }

    public func stats() -> PersonalStoreStats {
        PersonalStoreStats(unigrams: state.unigrams.count, bigrams: state.bigrams.count, trigrams: state.trigrams.count,
                           phrases: state.phrases.count, forgotten: state.forgotten.count,
                           neverCorrect: state.neverCorrect.count, estimatedMemoryBytes: state.estimatedMemoryBytes,
                           journalRecords: journalRecords)
    }

    /// Whole-state copy for export / tests.
    public func exportState() -> PersonalModelState { state }

    /// Current store time (injected clock).
    public var currentTime: Double { clock.now() }

    /// Applies externally planned mutations (import) as one journal transaction.
    public func apply(ops: [PersonalOp]) { commit(ops) }

    // MARK: Maintenance

    /// Deletes everything (memory, snapshot, journal).
    public func reset() {
        state.apply(.clear)
        cachedScorer = nil
        seq = 0; journalRecords = 0; journalBytes = 0
        do { try storage.destroy() } catch { storageErrorCount += 1 }
    }

    /// Prunes decayed/over-cap entries, writes a snapshot, and resets the journal.
    public func compact() { compactLocked() }

    // MARK: Internals

    private func commit(_ ops: [PersonalOp]) {
        guard !ops.isEmpty else { return }
        cachedScorer = nil
        var data = Data()
        for op in ops {
            seq += 1
            state.apply(op)
            data.append(PersonalJournalCodec.encodeLine(op, seq: seq))
        }
        var needsCompaction = overCap
        if persistenceEnabled {
            do {
                try storage.appendJournal(data)
                journalRecords += ops.count
                journalBytes += data.count
            } catch {
                storageErrorCount += 1
            }
        }
        if journalRecords >= config.journalMaxRecords || journalBytes >= config.journalMaxBytes { needsCompaction = true }
        if needsCompaction { compactLocked() }
    }

    private var overCap: Bool {
        state.unigrams.count > config.maxUnigrams || state.bigrams.count > config.maxBigrams
            || state.trigrams.count > config.maxTrigrams || state.phrases.count > config.maxPhrases
            || state.forgotten.count > config.maxForgotten || state.neverCorrect.count > config.maxNeverCorrect
    }

    private func compactLocked() {
        state.prune(config: config, at: clock.now())
        cachedScorer = nil
        guard persistenceEnabled else { return }
        do {
            // Snapshot first (it records `seq`), then drop the journal. A crash in between replays nothing twice
            // because replay skips records with seq <= snapshot seq.
            try storage.writeSnapshot(PersonalSnapshotCodec.encode(state, lastSeq: seq))
            try storage.resetJournal()
            journalRecords = 0
            journalBytes = 0
        } catch {
            storageErrorCount += 1
        }
    }
}
