import Foundation
import Synchronization
import Testing
import IBoardCore
import IBoardEngine
import IBoardLayout
@testable import IBoardUI

private final class MemorySeq: AppliedSequenceStore {
    private let v = Mutex(0)
    func load() -> Int { v.withLock { $0 } }
    func save(_ seq: Int) { v.withLock { $0 = seq } }
}

private func makeQueue(_ commands: [AppCommand]) -> CommandQueue {
    var q = CommandQueue()
    for c in commands { _ = q.append(c, at: 1000) }
    return q
}

@Suite("AppCommandApplier")
struct AppCommandApplierTests {
    private func rig(_ commands: [AppCommand], seq: MemorySeq = MemorySeq(), dir: URL? = nil)
        -> (AppCommandApplier, PersonalStore, MemorySeq) {
        let store = PersonalStore(storage: InMemoryPersonalStorage())
        let q = makeQueue(commands)
        return (AppCommandApplier(store: store, loadQueue: { q }, applied: seq, importDirectory: dir), store, seq)
    }

    @Test func addForgetAndNeverCorrectMapToTheStore() async {
        let (a, store, seq) = rig([
            .addWord(word: "hinglish", surface: "Hinglish"),
            .addWord(word: "zzyzx", surface: nil),
            .forgetWord(word: "zzyzx"),
            .setNeverCorrect(word: "teh", enabled: true),
        ])
        let r = await a.applyPending()
        #expect(r.applied == 4)
        #expect(await store.uses(of: "hinglish") > 0)
        #expect(await store.isForgotten("zzyzx"))
        #expect(await store.isNeverCorrect("teh"))
        #expect(seq.load() == 4)
    }

    @Test func eachCommandIsAppliedOnce() async {
        let (a, store, _) = rig([.addWord(word: "once", surface: nil)])
        _ = await a.applyPending()
        let uses = await store.uses(of: "once")
        let again = await a.applyPending()
        #expect(again.isEmpty)
        #expect(await store.uses(of: "once") == uses)
    }

    @Test func addingAForgottenWordRestoresIt() async {
        let (a, store, _) = rig([.forgetWord(word: "blip"), .addWord(word: "blip", surface: nil)])
        _ = await a.applyPending()
        #expect(await !store.isForgotten("blip"))
        #expect(await store.uses(of: "blip") > 0)
    }

    @Test func unforgetAndNeverCorrectOff() async {
        let (a, store, _) = rig([.forgetWord(word: "x1"), .unforgetWord(word: "x1"),
                                 .setNeverCorrect(word: "y1", enabled: true), .setNeverCorrect(word: "y1", enabled: false)])
        _ = await a.applyPending()
        #expect(await !store.isForgotten("x1"))
        #expect(await !store.isNeverCorrect("y1"))
    }

    @Test func clearPersonalDataWipesTheModelAndReportsIt() async {
        let (a, store, _) = rig([.addWord(word: "gone", surface: nil), .clearPersonalData, .resetInsights])
        let r = await a.applyPending()
        #expect(r.clearedPersonalData && r.resetInsights)
        #expect(await store.stats().unigrams == 0)
    }

    @Test func onlyNewerCommandsRunAfterTheStoredSequence() async {
        let seq = MemorySeq()
        seq.save(1)
        let (a, store, _) = rig([.addWord(word: "old", surface: nil), .addWord(word: "new", surface: nil)], seq: seq)
        let r = await a.applyPending()
        #expect(r.applied == 1)
        #expect(await store.uses(of: "old") == 0)
        #expect(await store.uses(of: "new") > 0)
    }

    @Test func aRecreatedQueueIsAppliedFromTheStart() async {
        let seq = MemorySeq()
        seq.save(40)
        let (a, store, _) = rig([.addWord(word: "fresh", surface: nil)], seq: seq)
        let r = await a.applyPending()
        #expect(r.applied == 1)
        #expect(await store.uses(of: "fresh") > 0)
        #expect(seq.load() == 1)
    }

    @Test func importMergesAFileFromTheImportDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Export a model that knows "kubernetes", import it into an empty one.
        let source = PersonalStore(storage: InMemoryPersonalStorage())
        await source.learn(word: "kubernetes", increment: 3)
        let name = try ImportPayloadStore(directory: dir).write(await source.exportDictionary())
        let (a, store, _) = rig([.importDictionary(fileName: name, replaceExisting: false)], dir: dir)
        let r = await a.applyPending()
        #expect(r.importedFiles == 1 && r.failed == 0)
        #expect(await store.uses(of: "kubernetes") > 0)
    }

    @Test func missingOrHostileImportsFailWithoutReadingElsewhere() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)")
        let (a, _, seq) = rig([.importDictionary(fileName: "import-missing.iboarddict", replaceExisting: false)], dir: dir)
        let r = await a.applyPending()
        #expect(r.failed == 1 && r.importedFiles == 0)
        #expect(seq.load() == 1) // a failed import is not retried forever
        let (b, _, _) = rig([], dir: dir)
        #expect(await b.applyPending().isEmpty)
    }
}

@MainActor
@Suite("InsightRecorder")
struct InsightRecorderTests {
    private final class Box { var t: TimeInterval = 0; var saved: [InsightCounters] = [] }

    @Test func countsWordsSwipesAndAutocorrect() {
        let box = Box()
        let r = InsightRecorder(now: { box.t })
        r.handle(.word(swiped: false)); r.handle(.word(swiped: true))
        r.handle(.autocorrect(accepted: true)); r.handle(.autocorrect(accepted: false))
        #expect(r.counters.wordsTyped == 2 && r.counters.swipeWords == 1)
        #expect(r.counters.autocorrectAccepted == 1 && r.counters.autocorrectReverted == 1)
    }

    @Test func idleGapSplitsSessionsAndShortOnesAreIgnored() {
        let box = Box()
        let r = InsightRecorder(now: { box.t })
        for i in 0..<10 { box.t = Double(i) * 1; r.handle(.word(swiped: false)) } // 9 s of typing
        box.t = 100
        r.handle(.word(swiped: false)) // gap > 8 s closes the first session
        #expect(r.counters.sessions == 1 && r.counters.sessionWords == 10)
        #expect(abs(r.counters.activeSeconds - 9) < 0.001)
        r.endSession() // a 0 s session: ignored
        #expect(r.counters.sessions == 1)
        #expect(r.counters.wordsTyped == 11)
    }

    @Test func persistsThrottledAndOnFlush() {
        let box = Box()
        let r = InsightRecorder(now: { box.t })
        r.persist = { box.saved.append($0) }
        r.handle(.word(swiped: false)) // first event persists
        box.t = 1
        r.handle(.word(swiped: false)) // within the interval: held
        #expect(box.saved.count == 1)
        r.flush()
        #expect(box.saved.count == 2 && box.saved[1].wordsTyped == 2)
        r.flush() // nothing changed
        #expect(box.saved.count == 2)
    }

    @Test func learnedWordsAreDeltasAfterTheBaseline() {
        let r = InsightRecorder()
        r.noteUnigramCount(100) // baseline from earlier launches
        #expect(r.counters.wordsLearned == 0)
        r.noteUnigramCount(103)
        r.noteUnigramCount(101) // forgetting lowers the baseline without subtracting
        r.noteUnigramCount(102)
        #expect(r.counters.wordsLearned == 4)
    }

    @Test func resetZeroesAndPersists() {
        let box = Box()
        let r = InsightRecorder(now: { box.t })
        r.persist = { box.saved.append($0) }
        r.handle(.word(swiped: false))
        r.reset(at: 1234)
        #expect(r.counters.wordsTyped == 0 && r.counters.resetAt == 1234)
        #expect(box.saved.last?.resetAt == 1234)
    }
}

@MainActor
@Suite("Coordinator insight events")
struct CoordinatorInsightTests {
    private final class P: TextProxy {
        var text = ""
        var contextBefore: String? { text }
        var hasText: Bool { !text.isEmpty }
        func insert(_ t: String) { text += t }
        func deleteBackwardOnce() { if !text.isEmpty { text.removeLast() } }
    }

    @Test func committedWordsAreCountedButNotWhileIncognito() {
        let c = TypingCoordinator(input: InputController(proxy: P()))
        let layout = LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters)
        c.setLayout(layout)
        func type(_ s: String) {
            for ch in s {
                if let k = layout.firstKey(.letter(String(ch))) {
                    c.trackTouch(id: 1, at: CGPoint(x: k.frame.midX, y: k.frame.midY))
                }
                c.insert(String(ch))
            }
        }
        var events: [InsightEvent] = []
        c.onInsight = { events.append($0) }
        type("hi ")
        #expect(events == [.word(swiped: false)])
        c.setIncognito(true)
        type("yo ")
        #expect(events.count == 1)
    }
}
