import Foundation
import Testing
@testable import IBoardEmoji

#if canImport(Darwin)
import Darwin
func physFootprintBytes() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}
#endif

@Test func bundledCatalogLoads() throws {
    let c = try EmojiCatalog.loadBundled()
    #expect(c.entries.count > 1800)
    #expect(c.groups.count == 9)
    let pizza = try #require(c.entries.first { $0.emoji == "🍕" })
    #expect(pizza.name == "pizza")
    #expect(c.groups[pizza.group] == "Food & Drink")
    #expect(!pizza.keywordsHI.isEmpty)
    #expect(pizza.keywordsHinglish.contains("khana"))
    // No skin-tone variants leak in as base entries.
    #expect(!c.entries.contains { $0.emoji.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } })
}

@Test func skinToneVariantsAreWellFormed() throws {
    let c = try EmojiCatalog.loadBundled()
    let wave = try #require(c.entries.first { $0.emoji == "👋" })
    #expect(wave.supportsSkinTone)
    #expect(wave.variant(.dark) == "👋🏿")
    #expect(wave.variant(nil) == "👋")
    let toned = c.entries.filter(\.supportsSkinTone)
    #expect(toned.count > 100)
    for e in toned {
        for (i, t) in SkinTone.allCases.enumerated() {
            #expect(e.tones[i].unicodeScalars.contains { $0.value == 0x1F3FB + UInt32(i) }, "\(e.name) \(t)")
        }
    }
    let pizza = try #require(c.entries.first { $0.emoji == "🍕" })
    #expect(pizza.variant(.dark) == "🍕")
}

@Test func recentsMoveToFrontDedupeAndCap() {
    var r = RecentEmoji(capacity: 3)
    for e in ["a", "b", "c", "a", "d"] { r.record(e) }
    #expect(r.items == ["d", "a", "c"])
    r.record("")
    #expect(r.items.count == 3)
}

@Test func skinToneMemoryResolvesOverrideThenDefault() throws {
    let c = try EmojiCatalog.loadBundled()
    let wave = try #require(c.entries.first { $0.emoji == "👋" })
    let heart = try #require(c.entries.first { $0.emoji == "❤️" })
    var m = SkinToneMemory()
    #expect(m.resolve(wave) == "👋")
    m.remember(.medium, for: wave, asDefault: true)
    #expect(m.resolve(wave) == "👋🏽")
    let thumbs = try #require(c.entries.first { $0.emoji == "👍" })
    #expect(m.resolve(thumbs) == "👍🏽")
    m.remember(.dark, for: thumbs)
    #expect(m.resolve(thumbs) == "👍🏿")
    #expect(m.resolve(heart) == "❤️")
    m.remember(nil, for: thumbs)
    #expect(m.resolve(thumbs) == "👍🏽")
}

@Test func skinToneOverridesAreBounded() throws {
    let c = try EmojiCatalog.loadBundled()
    var m = SkinToneMemory()
    for e in c.entries.filter(\.supportsSkinTone).prefix(SkinToneMemory.maxOverrides + 50) { m.remember(.light, for: e) }
    #expect(m.overrides.count == SkinToneMemory.maxOverrides)
}

@Test func preferencesRoundTripAndTolerateGarbage() throws {
    let c = try EmojiCatalog.loadBundled()
    var p = EmojiPreferences()
    let wave = try #require(c.entries.first { $0.emoji == "👋" })
    p.skinTones.remember(.light, for: wave, asDefault: true)
    #expect(p.pick(wave) == "👋🏻")
    #expect(EmojiPreferences.decode(p.encoded()) == p)
    #expect(EmojiPreferences.decode(Data("garbage".utf8)) == EmojiPreferences())
    #expect(EmojiPreferences.decode(nil) == EmojiPreferences())
}

@Test func storeLoadsLazilyAndDropsCaches() {
    let s = EmojiStore()
    #expect(!s.isLoaded)
    #expect(s.catalog() != nil)
    #expect(s.isLoaded)
    s.dropCaches()
    #expect(!s.isLoaded)
}

@Test func kaomojiCategoriesNonEmpty() {
    #expect(Kaomoji.categories.count >= 6)
    #expect(Kaomoji.categories.allSatisfy { !$0.items.isEmpty })
}

#if canImport(Darwin)
@Test func dataLayerMemoryDeltaIsMeasured() throws {
    // Data layer only (catalog resident). The UIKit grid's cost is NOT TESTED here.
    let before = physFootprintBytes()
    let s = EmojiStore()
    let c = try #require(s.catalog())
    let during = physFootprintBytes()
    let delta = Double(during - before) / 1_048_576
    print("EMOJI_MEMORY catalog entries=\(c.entries.count) footprint delta=\(String(format: "%.2f", delta)) MB")
    // Other tests run in parallel and pollute the process footprint, so the strict budget is opt-in:
    //   EMOJI_MEMORY_STRICT=1 swift test --no-parallel --filter dataLayerMemory
    let strict = ProcessInfo.processInfo.environment["EMOJI_MEMORY_STRICT"] == "1"
    #expect(delta < (strict ? 10 : 40), "data layer must fit the +10 MB panel budget")
    s.dropCaches()
}
#endif
