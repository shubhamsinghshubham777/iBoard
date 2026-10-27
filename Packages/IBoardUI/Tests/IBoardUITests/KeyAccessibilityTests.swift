import Testing
import IBoardLayout
@testable import IBoardUI

@Suite struct KeyAccessibilityTests {
    @Test func lettersFollowShift() {
        #expect(KeyAccessibility.info(for: .letter("q"), shift: .off).label == "q")
        #expect(KeyAccessibility.info(for: .letter("q"), shift: .once).label == "Q")
        #expect(KeyAccessibility.info(for: .letter("q"), shift: .capsLock).typesCharacter)
    }
    @Test func shiftReportsState() {
        #expect(KeyAccessibility.info(for: .shift, shift: .off).value == nil)
        #expect(KeyAccessibility.info(for: .shift, shift: .once).value == "on")
        #expect(KeyAccessibility.info(for: .shift, shift: .capsLock).value == "caps lock")
    }
    @Test func punctuationIsSpelledOut() {
        #expect(KeyAccessibility.info(for: .symbol("."), shift: .off).label == "period")
        #expect(KeyAccessibility.info(for: .symbol(","), shift: .off).label == "comma")
        #expect(KeyAccessibility.info(for: .symbol("7"), shift: .off).label == "7")
    }
    @Test func everyFunctionKeyHasAName() {
        let ids: [KeyIdentity] = [.delete, .space, .globe, .emoji, .layerSwitch(.numbers), .layerSwitch(.letters),
                                  .layerSwitch(.symbols)] + ReturnKeyKind.allCases.map { .returnKey($0) }
        for id in ids { #expect(!KeyAccessibility.info(for: id, shift: .off).label.isEmpty) }
        #expect(KeyAccessibility.info(for: .returnKey(.send), shift: .off, returnEnabled: false).value == "dimmed")
        #expect(KeyAccessibility.info(for: .globe, shift: .off).label == "next keyboard")
    }
    @Test func emptyStripSlotIsNotAnElement() {
        #expect(KeyAccessibility.stripLabel(slotIndex: 0, text: "") == nil)
        #expect(KeyAccessibility.stripLabel(slotIndex: 1, text: "hello") == "hello")
    }
}
