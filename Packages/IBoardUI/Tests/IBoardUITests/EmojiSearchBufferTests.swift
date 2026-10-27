import Testing
@testable import IBoardUI

@Suite struct EmojiSearchBufferTests {
    @Test func keepsLettersDigitsAndInnerSingleSpaces() {
        var b = EmojiSearchBuffer()
        let leading = b.append(" ")
        let word = b.append("pizza")
        let space = b.append(" ")
        let dbl = b.append(" ")
        let digit = b.append("2")
        let punct = b.append("!")
        #expect(!leading && word && space && !dbl && digit && !punct)
        #expect(b.text == "pizza 2")
        #expect(b.query == "pizza 2")
        b.append(" ")
        #expect(b.query == "pizza 2")
    }

    @Test func backspaceAndClear() {
        var b = EmojiSearchBuffer()
        b.append("ab")
        let removed = b.deleteBackward()
        #expect(removed && b.text == "a")
        b.clear()
        let none = b.deleteBackward()
        #expect(b.isEmpty && !none)
    }

    @Test func capsLengthAndAcceptsOtherScripts() {
        var b = EmojiSearchBuffer()
        b.append(String(repeating: "a", count: 40))
        #expect(b.text.count == EmojiSearchBuffer.maxLength)
        var h = EmojiSearchBuffer()
        h.append("पिज़्ज़ा")
        #expect(!h.isEmpty && h.text == "पिज़्ज़ा")
    }
}
