import Foundation
import Testing
@testable import IBoardEngine

private func makeStore(_ storage: InMemoryPersonalStorage = InMemoryPersonalStorage(),
                       clock: ManualPersonalClock = ManualPersonalClock(),
                       config: PersonalStoreConfig = PersonalStoreConfig()) -> (PersonalStore, InMemoryPersonalStorage, ManualPersonalClock) {
    (PersonalStore(storage: storage, clock: clock, config: config), storage, clock)
}

@Suite struct PersonalStoreTests {
    @Test func learnedWordAppearsInCompletionsAndKeepsCasing() async {
        let (store, _, _) = makeStore()
        await store.learn(word: "shubham", surface: "Shubham", increment: 0.3)
        await store.learn(word: "shuttle", increment: 1)
        let c = await store.scorer().completions(prefix: "Sh", limit: 5)
        #expect(c.map(\.word) == ["shuttle", "Shubham"])
        #expect(await store.uses(of: "SHUBHAM") == 1)
    }

    @Test func decayHalvesEveryHalfLife() async {
        let (store, _, clock) = makeStore()
        await store.learn(word: "alpha", increment: 1)
        #expect(abs(await store.effectiveWeight(of: "alpha") - 1) < 1e-6)
        clock.advance(days: 60)
        #expect(abs(await store.effectiveWeight(of: "alpha") - 0.5) < 1e-4)
        clock.advance(days: 60)
        #expect(abs(await store.effectiveWeight(of: "alpha") - 0.25) < 1e-4)
        // A new observation adds to the decayed value, not the original.
        await store.learn(word: "alpha", increment: 1)
        #expect(abs(await store.effectiveWeight(of: "alpha") - 1.25) < 1e-4)
        #expect(await store.uses(of: "alpha") == 2)
    }

    @Test func clockGoingBackwardsDoesNotInflate() async {
        let (store, _, clock) = makeStore()
        await store.learn(word: "beta", increment: 1)
        clock.advance(days: -10)
        #expect(await store.effectiveWeight(of: "beta") <= 1.0 + 1e-6)
    }

    @Test func recentWordsOutrankOldFrequentOnes() async {
        let (store, _, clock) = makeStore()
        for _ in 0..<4 { await store.learn(word: "oldword", increment: 1) }
        clock.advance(days: 180)
        await store.learn(word: "newword", increment: 1)
        let c = await store.scorer().completions(prefix: "", limit: 2)
        #expect(c.first?.word == "newword")
    }

    @Test func contextRaisesProbability() async {
        let (store, _, _) = makeStore()
        // As the learning tracker does: context words are themselves learned words, with their own bigram.
        for w in ["cup", "mug"] { for _ in 0..<5 { await store.learn(word: w, increment: 1) } }
        for _ in 0..<5 { await store.learn(word: "of", context: ["cup"], increment: 1) }
        for _ in 0..<5 { await store.learn(word: "of", context: ["mug"], increment: 1) }
        for _ in 0..<5 { await store.learn(word: "tea", context: ["cup", "of"], increment: 1) }
        for _ in 0..<5 { await store.learn(word: "coffee", context: ["mug", "of"], increment: 1) }
        let s = await store.scorer()
        let withCtx = s.score(word: "tea", context: ["cup", "of"])!
        let noCtx = s.score(word: "tea", context: [])!
        let wrongCtx = s.score(word: "tea", context: ["mug", "of"])!
        #expect(withCtx.probability > noCtx.probability)
        #expect(withCtx.probability > wrongCtx.probability)
        #expect(s.score(word: "nonexistent", context: []) == nil)
    }

    @Test func trustGrowsWithMassAndMixFallsBackToBase() async {
        #expect(PersonalInterpolation.trust(forMass: 0) == 0)
        #expect(PersonalInterpolation.trust(forMass: 10) < PersonalInterpolation.trust(forMass: 1000))
        #expect(PersonalInterpolation.trust(forMass: 1e9) <= PersonalInterpolation.maxWeight)
        let base = log(0.01)
        #expect(PersonalInterpolation.mix(baseLogProb: base, personal: nil) == base)
        let boosted = PersonalInterpolation.mix(baseLogProb: base, personal: PersonalScore(probability: 0.5, weight: 0.3))
        #expect(boosted > base)
        let expected = log(0.7 * 0.01 + 0.3 * 0.5)
        #expect(abs(boosted - expected) < 1e-9)
    }

    @Test func forgetRemovesEverywhereAndPersists() async {
        let (store, storage, clock) = makeStore()
        await store.learn(word: "zork", context: ["the", "old"], increment: 1)
        await store.learnPhrase(["the", "old", "zork"])
        await store.forget("Zork")
        let s = await store.exportState()
        #expect(s.unigrams["zork"] == nil)
        #expect(s.bigrams.isEmpty && s.trigrams.isEmpty && s.phrases.isEmpty)
        #expect(await store.isForgotten("zork"))
        #expect(await store.scorer().completions(prefix: "zo", limit: 3).isEmpty)
        let reopened = PersonalStore(storage: storage, clock: clock)
        #expect(await reopened.isForgotten("zork"))
        #expect(await reopened.forgetEntry(for: "zork")?.at == clock.now())
    }

    @Test func neverCorrectListPersists() async {
        let (store, storage, clock) = makeStore()
        await store.addNeverCorrect("Ayrin")
        await store.addNeverCorrect("lol")
        await store.removeNeverCorrect("lol")
        let reopened = PersonalStore(storage: storage, clock: clock)
        #expect(await reopened.neverCorrectWords() == ["ayrin"])
        #expect(await reopened.scorer().isNeverCorrect("AYRIN"))
    }

    @Test func repeatedPhrasesNeedTwoUses() async {
        let (store, _, _) = makeStore()
        await store.learnPhrase(["on", "my", "way"])
        #expect(await store.repeatedPhrases().isEmpty)
        await store.learnPhrase(["on", "my", "way"])
        #expect(await store.repeatedPhrases() == [["on", "my", "way"]])
        await store.learnPhrase(["too", "short"])  // 2 words: ignored
        #expect(await store.stats().phrases == 1)
    }

    // MARK: Persistence

    @Test func journalOnlyRoundTrip() async {
        let (store, storage, clock) = makeStore()
        await store.learn(word: "gamma", surface: "Gamma", context: ["a", "b"], increment: 0.5)
        await store.learn(word: "gamma", context: ["a", "b"], increment: 0.7)
        #expect(storage.snapshotData == nil)
        let reopened = PersonalStore(storage: storage, clock: clock)
        #expect(await reopened.exportState().unigrams == store.exportState().unigrams)
        #expect(await reopened.exportState().trigrams == store.exportState().trigrams)
        #expect(await reopened.exportState().surfaces == ["gamma": "Gamma"])
        #expect(await reopened.recovery.isClean)
    }

    @Test func compactionWritesSnapshotAndResetsJournal() async {
        var cfg = PersonalStoreConfig()
        cfg.journalMaxRecords = 10
        let (store, storage, clock) = makeStore(config: cfg)
        for i in 0..<12 { await store.learn(word: "word\(i)", increment: 1) }
        #expect(storage.snapshotData != nil)
        #expect(storage.journalData.count < 2000)
        let reopened = PersonalStore(storage: storage, clock: clock, config: cfg)
        #expect(await reopened.stats().unigrams == 12)
        #expect(await reopened.recovery.isClean)
    }

    @Test func crashBetweenSnapshotAndJournalResetDoesNotDoubleCount() async {
        var cfg = PersonalStoreConfig()
        cfg.journalMaxRecords = 1000
        let (store, storage, clock) = makeStore(config: cfg)
        await store.learn(word: "delta", increment: 1)
        await store.learn(word: "delta", increment: 1)
        let journalBefore = storage.journalData
        await store.compact()
        storage.journalData = journalBefore  // simulate: snapshot written, journal reset lost
        let reopened = PersonalStore(storage: storage, clock: clock, config: cfg)
        #expect(await reopened.uses(of: "delta") == 2)
        #expect(abs(await reopened.effectiveWeight(of: "delta") - 2) < 1e-5)
    }

    @Test func corruptSnapshotFallsBackToJournalAndReports() async {
        var cfg = PersonalStoreConfig()
        cfg.journalMaxRecords = 3
        let (store, storage, clock) = makeStore(config: cfg)
        for i in 0..<5 { await store.learn(word: "w\(i)", increment: 1) }  // compaction at 3 -> journal holds rest
        var snap = storage.snapshotData!
        snap[snap.count / 2] ^= 0xFF
        storage.snapshotData = snap
        let reopened = PersonalStore(storage: storage, clock: clock, config: cfg)
        let report = await reopened.recovery
        #expect(report.snapshotCorrupt)
        #expect(!report.isClean)
        let stats = await reopened.stats()
        #expect(stats.unigrams <= 5)       // whatever the journal still held
        // Store is usable and the next load is clean (corruption was repaired by rewriting).
        await reopened.learn(word: "after", increment: 1)
        let again = PersonalStore(storage: storage, clock: clock, config: cfg)
        #expect(await again.recovery.isClean)
        #expect(await again.uses(of: "after") == 1)
    }

    @Test func garbageAndTruncatedSnapshotsNeverCrash() async {
        let (store, storage, clock) = makeStore()
        await store.learn(word: "eps", increment: 1)
        await store.compact()
        let good = storage.snapshotData!
        var rng = SplitMix64(seed: 7)
        for _ in 0..<200 {
            var d = good
            switch rng.next() % 3 {
            case 0: d = d.prefix(Int(rng.next() % UInt64(d.count)))
            case 1: d[Int(rng.next() % UInt64(d.count))] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
            default: d = Data((0..<Int(rng.next() % 64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            }
            let s = InMemoryPersonalStorage()
            s.snapshotData = d
            _ = PersonalStore(storage: s, clock: clock)  // must not trap
        }
        _ = store
    }

    @Test func tornJournalTailIsSkippedAndNextAppendIsNotPoisoned() async {
        let (store, storage, clock) = makeStore()
        await store.learn(word: "zeta", increment: 1)
        await store.learn(word: "eta", increment: 1)
        storage.journalData = storage.journalData.dropLast(7)   // tear the last record
        let reopened = PersonalStore(storage: storage, clock: clock)
        #expect(await reopened.recovery.tornJournalTail)
        #expect(await reopened.uses(of: "zeta") == 1)
        #expect(await reopened.uses(of: "eta") == 0)
        await reopened.learn(word: "theta", increment: 1)
        let again = PersonalStore(storage: storage, clock: clock)
        #expect(await again.recovery.isClean)
        #expect(await again.uses(of: "theta") == 1)
    }

    @Test func corruptMiddleJournalLineIsSkipped() async {
        let (store, storage, clock) = makeStore()
        for w in ["one", "two", "three"] { await store.learn(word: w, increment: 1) }
        var lines = storage.journalData.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        lines[1][12] ^= 0x55
        storage.journalData = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        let reopened = PersonalStore(storage: storage, clock: clock)
        #expect(await reopened.recovery.corruptJournalLines == 1)
        #expect(await reopened.uses(of: "one") == 1)
        #expect(await reopened.uses(of: "two") == 0)
        #expect(await reopened.uses(of: "three") == 1)
    }

    @Test func failedWritesKeepMemoryStateAndNeverThrow() async {
        let (store, storage, _) = makeStore()
        storage.failWrites = true
        await store.learn(word: "kappa", increment: 1)
        #expect(await store.uses(of: "kappa") == 1)
        #expect(await store.storageErrorCount > 0)
    }

    @Test func capsBoundTablesAndKeepHeaviestEntries() async {
        var cfg = PersonalStoreConfig()
        cfg.maxUnigrams = 50
        cfg.maxBigrams = 40
        cfg.maxTrigrams = 40
        let (store, _, _) = makeStore(config: cfg)
        await store.learn(word: "keeper", increment: 50)
        for i in 0..<300 { await store.learn(word: "w\(i)", context: ["a", "b\(i)"], increment: 1) }
        await store.compact()
        let st = await store.stats()
        #expect(st.unigrams <= 50)
        #expect(st.bigrams <= 40 && st.trigrams <= 40)
        #expect(await store.uses(of: "keeper") == 1)
    }

    @Test func decayedEntriesArePruned() async {
        let (store, _, clock) = makeStore()
        await store.learn(word: "ephemeral", increment: 0.3)
        clock.advance(days: 400)
        await store.compact()
        #expect(await store.stats().unigrams == 0)
    }

    @Test func memoryEstimateAtDefaultCapsIsWithinBudget() async {
        // Estimate only (not a measurement): the default caps must stay far below the 30 MB keyboard budget.
        var s = PersonalModelState()
        let cfg = PersonalStoreConfig()
        for i in 0..<cfg.maxUnigrams { s.apply(.add(kind: .unigram, key: "word\(i)", increment: 1, surface: nil, at: 0)) }
        for i in 0..<cfg.maxBigrams { s.apply(.add(kind: .bigram, key: "word\(i)\u{1F}word\(i + 1)", increment: 1, surface: nil, at: 0)) }
        for i in 0..<cfg.maxTrigrams {
            s.apply(.add(kind: .trigram, key: "word\(i)\u{1F}word\(i + 1)\u{1F}word\(i + 2)", increment: 1, surface: nil, at: 0))
        }
        #expect(s.estimatedMemoryBytes < 8 * 1024 * 1024)
    }

    @Test func resetDeletesEverything() async {
        let (store, storage, clock) = makeStore()
        await store.learn(word: "lambda", increment: 1)
        await store.compact()
        await store.reset()
        #expect(storage.snapshotData == nil && storage.journalData.isEmpty)
        let reopened = PersonalStore(storage: storage, clock: clock)
        #expect(await reopened.stats().unigrams == 0)
    }

    // MARK: Storage modes

    @Test func fileStorageRoundTripAndFactory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iboard-personal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let local = base.appendingPathComponent("local")
        let group = base.appendingPathComponent("group")
        let noFA = PersonalStorageFactory.make(hasFullAccess: false, localDirectory: local, appGroupDirectory: group)
        #expect(noFA.mode == .extensionLocal)
        #expect(PersonalStorageFactory.make(hasFullAccess: true, localDirectory: local, appGroupDirectory: nil).mode == .extensionLocal)
        let withFA = PersonalStorageFactory.make(hasFullAccess: true, localDirectory: local, appGroupDirectory: group)
        #expect(withFA.mode == .appGroup)

        let clock = ManualPersonalClock()
        var cfg = PersonalStoreConfig()
        cfg.journalMaxRecords = 5
        let store = PersonalStore(storage: noFA, clock: clock, config: cfg)
        for i in 0..<8 { await store.learn(word: "file\(i)", context: ["x"], increment: 1) }
        let reopened = PersonalStore(storage: noFA, clock: clock, config: cfg)
        #expect(await reopened.stats().unigrams == 8)
        #expect(await reopened.recovery.isClean)

        // Full Access granted: migrate local -> group.
        #expect(try PersonalStorageFactory.migrate(from: noFA, to: withFA, config: cfg))
        let inGroup = PersonalStore(storage: withFA, clock: clock, config: cfg)
        #expect(await inGroup.stats().unigrams == 8)
        #expect(inGroup.storageMode == .appGroup)
    }

    @Test func migrateFromEmptySourceIsNoOp() throws {
        let a = InMemoryPersonalStorage(), b = InMemoryPersonalStorage(mode: .appGroup)
        #expect(try PersonalStorageFactory.migrate(from: a, to: b) == false)
        #expect(b.snapshotData == nil)
    }

    @Test func unwritableDirectoryDoesNotThrowIntoTyping() async {
        let storage = FilePersonalStorage(directory: URL(fileURLWithPath: "/dev/null/nope"), mode: .appGroup)
        let store = PersonalStore(storage: storage)
        await store.learn(word: "mu", increment: 1)
        #expect(await store.uses(of: "mu") == 1)
        #expect(await store.storageErrorCount > 0)
    }

    @Test func scorerSnapshotIsImmutableAcrossWrites() async {
        let (store, _, _) = makeStore()
        await store.learn(word: "nu", increment: 1)
        let before = await store.scorer()
        await store.learn(word: "xi", increment: 1)
        #expect(before.completions(prefix: "xi", limit: 3).isEmpty)
        #expect(await store.scorer().completions(prefix: "xi", limit: 3).count == 1)
    }
}
