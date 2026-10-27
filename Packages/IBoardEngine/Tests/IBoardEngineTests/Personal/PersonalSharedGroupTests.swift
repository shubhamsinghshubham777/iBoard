import Foundation
import Testing
@testable import IBoardEngine

/// Crash investigation (docs/agent-reports/crash.md): first-run migration into a not-yet-existing App Group `personal/`
/// folder, and two PersonalStore instances (keyboard + app sync) over the same folder.
@Suite struct PersonalSharedGroupTests {
    private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("iboard-\(UUID().uuidString)") }

    @Test func migratesIntoMissingGroupDirectoryThenTwoStoresCoexist() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let local = FilePersonalStorage(directory: root.appendingPathComponent("local/personal"), mode: .extensionLocal)
        let group = FilePersonalStorage(directory: root.appendingPathComponent("group/personal"), mode: .appGroup)
        let a = PersonalStore(storage: local)
        for i in 0..<30 { await a.learn(word: "word\(i)", context: ["x", "y"], increment: 1) }
        #expect(try group.readSnapshot() == nil)
        #expect(try group.readJournal().isEmpty)
        #expect(try PersonalStorageFactory.migrate(from: local, to: group))
        let keyboard = PersonalStore(storage: group)
        let app = PersonalStore(storage: group)
        #expect(await keyboard.stats().unigrams >= 30)
        #expect(await app.stats().unigrams >= 30)
        await withTaskGroup(of: Void.self) { g in
            g.addTask { for i in 0..<50 { await keyboard.learn(word: "kb\(i)", increment: 1) } }
            g.addTask { for i in 0..<50 { await app.learn(word: "app\(i)", increment: 1) } }
        }
        let reopened = PersonalStore(storage: group)
        #expect(await reopened.stats().unigrams >= 30)
    }

    @Test func corruptSnapshotAndJournalDoNotTrap() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = FilePersonalStorage(directory: root, mode: .appGroup)
        try s.writeSnapshot(Data([0, 1, 2, 3, 255, 255, 255]))
        try s.appendJournal(Data("garbage\n{\"x\":1}\n\u{0}\u{1}".utf8))
        let store = PersonalStore(storage: s)
        await store.learn(word: "ok", increment: 1)
        #expect(await store.uses(of: "ok") == 1)
        #expect(await store.recovery.snapshotCorrupt)
    }
}
