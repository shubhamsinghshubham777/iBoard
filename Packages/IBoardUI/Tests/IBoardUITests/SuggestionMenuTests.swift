import Testing
import IBoardEngine
@testable import IBoardUI

@Suite struct SuggestionMenuTests {
    @Test func menuForWord() {
        let m = SuggestionMenu.menu(for: SuggestionSlot(text: "teh", role: .literal), at: 1)
        #expect(m?.word == "teh")
        #expect(m?.banner == "\u{201C}teh\u{201D}")
        #expect(SuggestionMenu.actionTitles == ["Forget", "Never correct", "Cancel"])
    }
    @Test func noMenuForJunk() {
        #expect(SuggestionMenu.menu(for: nil, at: 0) == nil)
        #expect(SuggestionMenu.menu(for: SuggestionSlot(text: "a", role: .best), at: 0) == nil)
        #expect(SuggestionMenu.menu(for: SuggestionSlot(text: "see you", role: .phrase), at: 0) == nil)
        #expect(SuggestionMenu.menu(for: SuggestionSlot(text: "123456", role: .best), at: 0) == nil)
    }
}
