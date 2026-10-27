import Foundation
import Testing
@testable import IBoardEmoji

private let shared: EmojiSearchIndex = {
    EmojiSearchIndex(catalog: try! EmojiCatalog.loadBundled())
}()

private func top(_ q: String, _ n: Int = 5) -> [String] {
    shared.search(q, limit: n).map { shared.catalog.entries[$0.entryIndex].emoji }
}

@Test func englishKeywordSearch() {
    #expect(top("pizza").first == "🍕")
    #expect(top("grinning").first == "😀")
    #expect(top("heart eyes").contains("😍"))
    #expect(top("thumbs up").first == "👍")
}

@Test func prefixOnLastTokenOnly() {
    #expect(top("pizz").contains("🍕"))
    #expect(top("pi zza").isEmpty)
}

@Test func hindiDevanagariSearch() {
    // Both composed (U+095B) and decomposed nukta input must find the pizza emoji.
    #expect(top("पिज़्ज़ा").contains("🍕"))
    #expect(top("\u{092A}\u{093F}\u{091C}\u{093C}\u{094D}\u{091C}\u{093C}\u{093E}").contains("🍕"))
}

@Test func hinglishOverlaySearch() {
    #expect(top("billi").contains("🐱"))
    #expect(top("diya").contains("🪔"))
    #expect(top("namaste").contains("🙏"))
    #expect(top("chai").contains("☕"))
    #expect(top("gussa").contains("😡"))
    #expect(top("haathi").first == "🐘")
}

@Test func accentsAndCaseFold() {
    #expect(top("PIZZA").first == "🍕")
    #expect(top("  pizza!! ").first == "🍕")
}

@Test func emptyAndGarbageQueries() {
    #expect(shared.search("").isEmpty)
    #expect(shared.search("   ").isEmpty)
    #expect(shared.search("zzzzqqqq").isEmpty)
    #expect(shared.search("pizza", limit: 0).isEmpty)
}

@Test func nameMatchOutranksKeywordMatch() {
    // "cat" is the name word of the cat faces, only a keyword of other animals.
    let names = shared.search("cat", limit: 3).map { shared.catalog.entries[$0.entryIndex].name }
    #expect(names.allSatisfy { $0.contains("cat") })
}

@Test func predictionAfterWord() {
    func p(_ w: String) -> [String] { shared.predict(afterWord: w).map { shared.catalog.entries[$0].emoji } }
    #expect(p("pizza").first == "🍕")
    #expect(p("Pizza").first == "🍕")
    #expect(p("diya").first == "🪔")
    #expect(p("billi").first == "🐱")
}

@Test func predictionIsConservative() {
    func p(_ w: String) -> [Int] { shared.predict(afterWord: w) }
    #expect(p("the").isEmpty)
    #expect(p("it").isEmpty)           // too short
    #expect(p("").isEmpty)
    #expect(p("two words").isEmpty)    // exactly one word is required
    #expect(p("face").isEmpty)         // generic token carried by dozens of emoji
    #expect(p("pizz").isEmpty)         // no prefix prediction mid-word
    for w in ["and", "you", "hello", "okay", "please", "with", "have", "this", "that", "good"] {
        #expect(p(w).count <= 3)
    }
}

@Test func storeBuildsIndexLazilyAndDrops() {
    let s = EmojiStore()
    #expect(s.searchIndex() != nil)
    s.dropCaches()
    #expect(!s.isLoaded)
}

@Test func searchLatencyP95() {
    let queries = ["pizza", "heart", "smi", "hap", "face with", "thumbs", "flag", "cat", "billi", "pyaar", "diya", "पिज़्ज़ा",
                   "खुश", "red heart", "grin", "party", "birthday", "dog", "sun", "rain", "car", "food", "love", "😀", "a", "s", "ho", "namaste",
                   "gussa", "khana", "man", "woman", "baby", "hand", "tree", "moon", "star", "fire", "cry", "laugh"]
    for q in queries { _ = shared.search(q) } // warm
    var times: [Double] = []
    for _ in 0..<25 {
        for q in queries {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = shared.search(q)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
    }
    times.sort()
    let p95 = times[Int(Double(times.count) * 0.95)]
    let worst = times.last!
    print("EMOJI_SEARCH_LATENCY n=\(times.count) p50=\(String(format: "%.3f", times[times.count / 2])) ms p95=\(String(format: "%.3f", p95)) ms max=\(String(format: "%.3f", worst)) ms")
    #expect(p95 < 30)
}

@Test func indexBuildTime() throws {
    let c = try EmojiCatalog.loadBundled()
    let t0 = DispatchTime.now().uptimeNanoseconds
    _ = EmojiSearchIndex(catalog: c)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    print("EMOJI_INDEX_BUILD \(String(format: "%.1f", ms)) ms")
}
