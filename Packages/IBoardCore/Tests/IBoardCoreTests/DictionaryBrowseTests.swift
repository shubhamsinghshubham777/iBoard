import Foundation
import Testing
@testable import IBoardCore

@Suite struct DictionaryBrowseTests {
    let base = [
        DictionaryEntry(word: "cafe", surface: "Café", weight: 3, uses: 9),
        DictionaryEntry(word: "naya", weight: 5, uses: 2),
        DictionaryEntry(word: "kya", weight: 1, uses: 20),
    ]

    @Test func searchAndSort() {
        #expect(DictionaryBrowse.filter(base, query: "CAFE", sort: .weight).map(\.word) == ["cafe"])
        #expect(DictionaryBrowse.filter(base, query: "é", sort: .weight).map(\.word) == ["cafe"])
        #expect(DictionaryBrowse.filter(base, query: " ", sort: .weight).map(\.word) == ["naya", "cafe", "kya"])
        #expect(DictionaryBrowse.filter(base, query: "", sort: .uses).map(\.word) == ["kya", "cafe", "naya"])
        #expect(DictionaryBrowse.filter(base, query: "", sort: .alphabetical).map(\.word) == ["cafe", "kya", "naya"])
        #expect(DictionaryBrowse.filter(base, query: "zzz", sort: .weight).isEmpty)
    }

    @Test func overlayShowsQueuedEdits() {
        let r = DictionaryBrowse.applying([
            .forgetWord(word: "kya"), .addWord(word: "new", surface: "New"),
            .setNeverCorrect(word: "naya", enabled: true), .importDictionary(fileName: "import-a.iboarddict", replaceExisting: false),
        ], to: base)
        let m = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.word, $0) })
        #expect(m["kya"] == nil)
        #expect(m["new"]?.pendingAdd == true && m["new"]?.display == "New")
        #expect(m["naya"]?.neverCorrect == true)
        #expect(r.unpreviewable == 1)
        #expect(DictionaryBrowse.applying([.clearPersonalData], to: base).entries.isEmpty)
    }
}
