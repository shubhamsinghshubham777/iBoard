import Foundation
import Testing
@testable import IBoardCore

@Suite struct AppCommandsTests {
    @Test func wordNormalization() {
        #expect(CommandWord.normalize("  Shubham ") == "shubham")
        #expect(CommandWord.normalize("") == nil)
        #expect(CommandWord.normalize("two words") == nil)
        #expect(CommandWord.normalize("a\nb") == nil)
        #expect(CommandWord.normalize(String(repeating: "a", count: 65)) == nil)
        #expect(AppCommand.makeAddWord("Shubham", surface: "Shubham") == .addWord(word: "shubham", surface: "Shubham"))
        #expect(AppCommand.makeAddWord("shubham", surface: "Other") == .addWord(word: "shubham", surface: nil))
        #expect(AppCommand.makeForget("a b") == nil)
    }

    @Test func roundTripAllCommands() throws {
        var q = CommandQueue()
        let cmds: [AppCommand] = [
            .addWord(word: "naya", surface: "Naya"), .forgetWord(word: "x"), .unforgetWord(word: "x"),
            .setNeverCorrect(word: "kya", enabled: true), .importDictionary(fileName: "import-abc.iboarddict", replaceExisting: true),
            .resetInsights, .clearPersonalData,
        ]
        for (i, c) in cmds.enumerated() { #expect(q.append(c, at: Double(i)) == i + 1) }
        let back = try #require(CommandQueue.decode(q.encoded()))
        #expect(back == q)
        #expect(back.entries.map(\.command) == cmds)
    }

    @Test func pendingAfterAcknowledged() {
        var q = CommandQueue()
        for _ in 0..<5 { q.append(.resetInsights, at: 1) }
        #expect(q.pending(after: 0).count == 5)
        #expect(q.pending(after: 3).map(\.seq) == [4, 5])
        #expect(q.pending(after: 5).isEmpty)
    }

    @Test func capDropsOldestKeepsSequence() {
        var q = CommandQueue()
        for _ in 0..<(CommandQueue.maxEntries + 20) { q.append(.resetInsights, at: 1) }
        #expect(q.entries.count == CommandQueue.maxEntries)
        #expect(q.entries.first?.seq == 21)
        #expect(q.nextSeq == CommandQueue.maxEntries + 21)
    }

    @Test func badEntriesAreSkippedIndividually() throws {
        let json = """
        {"version":1,"nextSeq":4,"entries":[
         {"seq":1,"created":1,"command":{"type":"forgetWord","word":"ok"}},
         {"seq":2,"created":1,"command":{"type":"futureThing"}},
         {"seq":3,"created":1,"command":{"type":"addWord","word":"bad word"}}]}
        """
        let q = try #require(CommandQueue.decode(Data(json.utf8)))
        #expect(q.entries.count == 1)
        #expect(q.skippedOnDecode == 2)
    }

    @Test func rejectsCorruptNewerAndOversize() {
        #expect(CommandQueue.decode(Data("nope".utf8)) == nil)
        #expect(CommandQueue.decode(Data(#"{"version":9,"nextSeq":1,"entries":[]}"#.utf8)) == nil)
        #expect(CommandQueue.decode(Data(count: CommandQueue.maxBytes + 1)) == nil)
    }

    @Test func nextSeqRepairedWhenDamaged() throws {
        let json = #"{"version":1,"nextSeq":1,"entries":[{"seq":7,"created":1,"command":{"type":"resetInsights"}}]}"#
        let q = try #require(CommandQueue.decode(Data(json.utf8)))
        #expect(q.nextSeq == 8)
    }

    @Test func importFileNameValidation() {
        #expect(ImportPayloadStore.isValidFileName("import-abc-1.iboarddict"))
        #expect(!ImportPayloadStore.isValidFileName("../x.iboarddict"))
        #expect(!ImportPayloadStore.isValidFileName("a/b.iboarddict"))
        #expect(!ImportPayloadStore.isValidFileName("x.txt"))
        #expect(!ImportPayloadStore.isValidFileName(".hidden.iboarddict"))
        let bad = #"{"version":1,"nextSeq":2,"entries":[{"seq":1,"created":1,"command":{"type":"importDictionary","fileName":"../../etc.iboarddict"}}]}"#
        #expect(CommandQueue.decode(Data(bad.utf8))?.entries.isEmpty == true)
    }

    @Test func storePersistsAndSequences() throws {
        let suite = "test.cmd.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let s = CommandQueueStore(defaults: d)
        #expect(s.enqueue(.resetInsights, at: 1) == 1)
        #expect(s.enqueue(.forgetWord(word: "a"), at: 2) == 2)
        #expect(CommandQueueStore(defaults: d).load().entries.count == 2)
    }

    @Test func payloadStoreWritesAndRejects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iboard-imp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = ImportPayloadStore(directory: dir)
        let name = try p.write(Data("x".utf8))
        #expect(ImportPayloadStore.isValidFileName(name))
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == Data("x".utf8))
        #expect(throws: ImportPayloadStore.Failure.empty) { try p.write(Data()) }
        #expect(throws: ImportPayloadStore.Failure.tooLarge) { try p.write(Data(count: ImportPayloadStore.maxBytes + 1)) }
        p.prune(olderThan: -1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
    }
}

@Suite struct InsightsTests {
    @Test func derivedStats() {
        var c = InsightCounters()
        #expect(c.isEmpty && c.averageWPM == nil && c.swipeShare == nil && c.autocorrectRevertRate == nil)
        for i in 0..<10 { c.recordWord(swiped: i < 4) }
        c.recordSession(words: 20, seconds: 30)
        c.recordSession(words: 5, seconds: 1)  // too short, ignored
        c.recordAutocorrect(accepted: true); c.recordAutocorrect(accepted: true); c.recordAutocorrect(accepted: true)
        c.recordAutocorrect(accepted: false)
        #expect(c.swipeShare == 0.4)
        #expect(c.averageWPM == 40)
        #expect(c.sessions == 1)
        #expect(c.autocorrectRevertRate == 0.25)
        #expect(!c.isEmpty)
    }

    @Test func resetZeroesAndStamps() {
        var c = InsightCounters()
        c.recordWord(swiped: true); c.recordLearnedWord()
        c.reset(at: 42)
        #expect(c.isEmpty && c.resetAt == 42)
    }

    @Test func tolerantDecoding() throws {
        let c = try JSONDecoder().decode(InsightCounters.self, from: Data(#"{"wordsTyped":5,"swipeWords":99,"sessions":-3,"activeSeconds":-1}"#.utf8))
        #expect(c.wordsTyped == 5 && c.swipeWords == 5 && c.sessions == 0 && c.activeSeconds == 0)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(InsightCounters.self, from: Data(#"{"version":5}"#.utf8)) }
    }

    @Test func storeRoundTripAndReset() throws {
        let suite = "test.ins.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let s = InsightsStore(defaults: d)
        #expect(s.load() == nil)
        var c = InsightCounters(); c.recordWord(swiped: false); c.recordLearnedWord()
        s.save(c)
        #expect(s.load() == c)
        let r = s.reset(at: 9)
        #expect(r.isEmpty && s.load()?.resetAt == 9)
    }

    @Test func noTextInEncoding() throws {
        var c = InsightCounters(); c.recordWord(swiped: true)
        let s = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!s.contains("\"word\""))
    }
}
