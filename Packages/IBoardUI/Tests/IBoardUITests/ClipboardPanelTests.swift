import Foundation
import Testing
@testable import IBoardUI
import IBoardEngine

@Suite struct ClipboardPanelTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func rowsPinnedFirstWithAges() {
        var h = ClipboardHistory()
        h.record("older note", changeCount: 1, at: t0)
        h.record("newer note", changeCount: 2, at: t0 + 300)
        h.setPinned(h.items.first { $0.text == "older note" }!.id, true)
        let m = ClipboardPanelModel(history: h, now: t0 + 600)
        #expect(m.rows.map(\.text) == ["older note", "newer note"])
        #expect(m.rows[0].age == "Pinned" && m.rows[1].age == "5 min ago")
        #expect(m.rows[0].accessibilityLabel.hasPrefix("Pinned. older note"))
        #expect(m.canClear)
    }

    @Test func expiredItemsAreNotShownAndEmptyCannotClear() {
        var h = ClipboardHistory()
        h.record("gone soon", changeCount: 1, at: t0)
        let m = ClipboardPanelModel(history: h, now: t0 + 4000)
        #expect(m.rows.isEmpty && !m.canClear)
    }

    @Test func ttlTextFollowsHistoryTTL() {
        #expect(ClipboardPanelModel.footer(ttl: 3600).contains("1 hour"))
        #expect(ClipboardPanelModel.footer(ttl: 1800).contains("30 minutes"))
        #expect(ClipboardPanelModel.footer(ttl: 7200).contains("2 hours"))
        let h = ClipboardHistory(ttl: 300)
        #expect(ClipboardPanelModel(history: h, now: t0).footer.contains("5 minutes"))
    }

    @Test func shortTTLExpiresItems() {
        var h = ClipboardHistory(ttl: 300)
        h.record("short lived", changeCount: 1, at: t0)
        #expect(ClipboardPanelModel(history: h, now: t0 + 301).rows.isEmpty)
    }

    @Test func clearAllRemovesPinnedToo() {
        var h = ClipboardHistory()
        h.record("a b", changeCount: 1, at: t0)
        h.setPinned(h.items[0].id, true)
        h.clearAll()
        #expect(ClipboardPanelModel(history: h, now: t0).rows.isEmpty)
    }

    @Test func stripTypeScaleIsCapped() {
        #expect(StripTypeScale.size(base: 16, scaled: 16) == 16)
        #expect(StripTypeScale.size(base: 16, scaled: 20) == 20)
        #expect(StripTypeScale.size(base: 16, scaled: 40) == 16 * StripTypeScale.maxFactor)
        #expect(StripTypeScale.size(base: 16, scaled: 12) == 16)
    }

    @Test func replacementPolicy() {
        #expect(TextReplacementPolicy.shouldExpand(token: "omw", secure: false, enabled: true))
        #expect(!TextReplacementPolicy.shouldExpand(token: "omw", secure: true, enabled: true))
        #expect(!TextReplacementPolicy.shouldExpand(token: "omw", secure: false, enabled: false))
        #expect(!TextReplacementPolicy.shouldExpand(token: "", secure: false, enabled: true))
        #expect(!TextReplacementPolicy.shouldExpand(token: String(repeating: "a", count: 41), secure: false, enabled: true))
    }

    @Test func fingerprintRoundTrip() {
        let v = SystemLexiconSnapshot(entries: [.init(userInput: "omw", documentText: "On my way!")]).fingerprint
        #expect(SystemLexiconFingerprintStore.decode(SystemLexiconFingerprintStore.encode(v)) == v)
        #expect(SystemLexiconFingerprintStore.decode(nil) == nil && SystemLexiconFingerprintStore.decode("x") == nil)
        #expect(SystemLexiconFingerprintStore.decode(SystemLexiconFingerprintStore.encode(.max)) == .max)
    }
}
