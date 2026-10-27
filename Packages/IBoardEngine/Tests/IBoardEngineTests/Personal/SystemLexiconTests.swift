import Foundation
import Synchronization
import Testing
@testable import IBoardEngine

private final class MutableSource: SystemLexiconSource, Sendable {
    private let list: Mutex<[SystemLexiconEntry]>
    init(_ l: [SystemLexiconEntry]) { list = Mutex(l) }
    func set(_ l: [SystemLexiconEntry]) { list.withLock { $0 = l } }
    func entries() async -> [SystemLexiconEntry] { list.withLock { $0 } }
}

private func e(_ a: String, _ b: String? = nil) -> SystemLexiconEntry { SystemLexiconEntry(userInput: a, documentText: b ?? a) }

@Suite struct SystemLexiconTests {
    let entries = [e("omw", "On my way!"), e("Priya"), e("Rohan"), e("ddg", "Dum dum garam"), e("12345"), e(""), e("Anaïs")]

    @Test func classifiesNamesAndReplacements() {
        let s = SystemLexiconSnapshot(entries: entries)
        #expect(s.expansion(for: "OMW") == "On my way!")
        #expect(s.expansion(for: "priya") == nil)
        #expect(s.names == ["Anaïs", "Priya", "Rohan"])
        #expect(s.names(withPrefix: "pr") == ["Priya"])
        #expect(s.isKnownName("rohan") && !s.isKnownName("12345"))
    }

    @Test func fingerprintIsOrderIndependentAndContentSensitive() {
        let a = SystemLexiconSnapshot(entries: entries), b = SystemLexiconSnapshot(entries: entries.reversed())
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.fingerprint != SystemLexiconSnapshot(entries: entries + [e("Zoya")]).fingerprint)
        #expect(SystemLexiconSnapshot(entries: []).fingerprint == 0)
    }

    @Test func capsBoundMemory() {
        let many = (0..<(SystemLexiconSnapshot.maxNames + 500)).map { e("name\(String(repeating: "a", count: $0 % 7))\($0)x") }
        #expect(SystemLexiconSnapshot(entries: many).names.count == SystemLexiconSnapshot.maxNames)
    }

    @Test func refreshIsCheapWhenUnchangedAndSeedsOnlyNewNames() async {
        let src = MutableSource(entries)
        let store = PersonalStore(storage: InMemoryPersonalStorage())
        let imp = SystemLexiconImporter(source: src, store: store)
        let r1 = await imp.refresh()
        #expect(r1.outcome == .updated && r1.namesAdded == 3 && r1.replacementsTotal == 2)
        #expect(await store.uses(of: "priya") == 1)
        let r2 = await imp.refresh()
        #expect(r2.outcome == .unchanged && r2.namesAdded == 0)
        #expect(await store.uses(of: "priya") == 1)       // not re-seeded
        src.set(entries + [e("Zoya")])
        let r3 = await imp.refresh()
        #expect(r3.outcome == .updated && r3.namesAdded == 1 && r3.namesRemoved == 0)
        let uz = await store.uses(of: "zoya"), up = await store.uses(of: "priya")
        #expect(uz == 1 && up == 1)
        src.set([e("Zoya")])
        let r4 = await imp.refresh()
        let cur = await imp.current
        #expect(r4.namesRemoved == 3 && cur.names == ["Zoya"])
    }

    @Test func previousFingerprintSkipsReseedAfterRestart() async {
        let src = MutableSource(entries)
        let fp = SystemLexiconSnapshot(entries: entries).fingerprint
        let store = PersonalStore(storage: InMemoryPersonalStorage())
        let imp = SystemLexiconImporter(source: src, store: store, previousFingerprint: fp)
        _ = await imp.refresh()
        #expect(await store.uses(of: "priya") == 0)
        #expect((await imp.current).names.count == 3)
    }

    @Test func emptySourceIsSafe() async {
        let imp = SystemLexiconImporter(source: MutableSource([]))
        let r = await imp.refresh()
        #expect(r.outcome == .updated && r.replacementsTotal == 0)
        #expect(await imp.refresh().outcome == .unchanged)
    }
}
