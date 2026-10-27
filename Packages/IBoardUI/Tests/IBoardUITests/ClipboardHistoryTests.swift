import Foundation
import Testing
@testable import IBoardUI

@Suite struct ClipboardHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func recordsNewestFirstAndDedupes() {
        var h = ClipboardHistory()
        h.record("one", changeCount: 1, at: t0)
        h.record("two", changeCount: 2, at: t0 + 1)
        h.record("one", changeCount: 3, at: t0 + 2)
        #expect(h.items.map(\.text) == ["one", "two"])
        #expect(h.lastChangeCount == 3)
        #expect(h.needsRead(changeCount: 3) == false && h.needsRead(changeCount: 4))
    }
    @Test func capAndPinning() {
        var h = ClipboardHistory()
        h.record("keep", changeCount: 0, at: t0)
        h.setPinned(h.items[0].id, true)
        for i in 1...30 { h.record("item \(i)", changeCount: i, at: t0 + Double(i)) }
        #expect(h.items.count == ClipboardHistory.maxItems)
        #expect(h.items.contains { $0.text == "keep" && $0.pinned })
        #expect(h.visible(at: t0 + 31).first?.text == "keep")
    }
    @Test func expiryAndCodeTTL() {
        var h = ClipboardHistory()
        h.record("hello world", changeCount: 1, at: t0)
        h.record("482913", changeCount: 2, at: t0)
        #expect(h.items.first { $0.text == "482913" }?.isCode == true)
        #expect(h.visible(at: t0 + 601).map(\.text) == ["hello world"])
        #expect(h.visible(at: t0 + 3601).isEmpty)
        h.setPinned(h.items.first { $0.text == "hello world" }!.id, true)
        #expect(h.visible(at: t0 + 99999).map(\.text) == ["hello world"])
    }
    @Test func rejectsEmptyAndHuge() {
        var h = ClipboardHistory()
        let a = h.record("   ", changeCount: 1, at: t0)
        let b = h.record(nil, changeCount: 2, at: t0)
        let c = h.record(String(repeating: "a", count: 2001), changeCount: 3, at: t0)
        #expect(!a && !b && !c)
        #expect(h.items.isEmpty && h.lastChangeCount == 3)
    }
    @Test func storeRoundTripDeletesExpiredFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(url: dir.appendingPathComponent("clipboard.json"))
        var h = ClipboardHistory()
        h.record("alpha beta", changeCount: 1, at: t0)
        store.save(h, now: t0)
        #expect(store.load(now: t0).items.map(\.text) == ["alpha beta"])
        store.save(h, now: t0 + 7200)
        let onDisk = try JSONDecoder().decode(ClipboardHistory.self, from: Data(contentsOf: store.url))
        #expect(onDisk.items.isEmpty)
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load().items.isEmpty)
    }
    @Test func clearAllAndPreview() {
        var h = ClipboardHistory()
        h.record("x y", changeCount: 1, at: t0)
        h.setPinned(h.items[0].id, true)
        h.clearAll()
        #expect(h.items.isEmpty)
        #expect(ClipboardHistory.preview("a\nb") == "a b")
        #expect(ClipboardHistory.preview(String(repeating: "z", count: 40)).count == 18)
    }
}
