import Testing
import IBoardLayout
@testable import IBoardUI

private final class FakeProxy: TextProxy {
    var text = ""
    var contextBefore: String? { text.isEmpty ? nil : text }
    var hasText: Bool { !text.isEmpty }
    func insert(_ t: String) { text += t }
    func deleteBackwardOnce() { if !text.isEmpty { text.removeLast() } } // Character == grapheme
}

@Test func autoCapSentences() {
    func s(_ t: String?) -> ShiftState { AutoCapitalizer.shift(mode: .sentences, before: t) }
    #expect(s(nil) == .once)
    #expect(s("") == .once)
    #expect(s("   ") == .once)
    #expect(s("Hello") == .off)
    #expect(s("Hello.") == .off) // no space yet
    #expect(s("Hello. ") == .once)
    #expect(s("Hello!  ") == .once)
    #expect(s("Really? ") == .once)
    #expect(s("Hello, ") == .off)
    #expect(s("Hello\n") == .once)
    #expect(s("Hello.\n") == .once)
    #expect(s("He said \"go.\" ") == .once)
    #expect(s("(done.) ") == .once)
    #expect(s("Hello world ") == .off)
    #expect(s("नमस्ते। ") == .once)
    #expect(s("wait... ") == .once)
}

@Test func autoCapOtherModes() {
    #expect(AutoCapitalizer.shift(mode: .none, before: nil) == .off)
    #expect(AutoCapitalizer.shift(mode: .allCharacters, before: "abc") == .capsLock)
    #expect(AutoCapitalizer.shift(mode: .words, before: "abc") == .off)
    #expect(AutoCapitalizer.shift(mode: .words, before: "abc ") == .once)
    #expect(AutoCapitalizer.shift(mode: .words, before: "") == .once)
}

@Test func returnKeyStyles() {
    #expect(ReturnKeyStyle.label(for: .default) == "return")
    #expect(ReturnKeyStyle.label(for: .search) == "search")
    #expect(ReturnKeyStyle.label(for: .emergencyCall) == nil)
    #expect(!ReturnKeyStyle.isProminent(.default))
    #expect(!ReturnKeyStyle.isProminent(.next))
    #expect(ReturnKeyStyle.isProminent(.send))
    #expect(ReturnKeyStyle.isProminent(.go))
}

@Test func returnKeyDisabledWhenEmptyAndAutoEnabled() {
    let p = FakeProxy()
    let c = InputController(proxy: p, traits: InputFieldTraits(enablesReturnKeyAutomatically: true))
    #expect(!c.isReturnKeyEnabled)
    #expect(!c.returnKey())
    #expect(p.text == "")
    c.insert("a")
    #expect(c.isReturnKeyEnabled)
    #expect(c.returnKey())
    #expect(p.text == "a\n")
    let free = InputController(proxy: FakeProxy())
    #expect(free.returnKey())
}

@Test func deleteIsGraphemeCorrect() {
    let p = FakeProxy()
    let c = InputController(proxy: p)
    c.insert("a👨‍👩‍👧é")
    c.deleteBackward()
    #expect(p.text == "a👨‍👩‍👧")
    c.deleteBackward()
    #expect(p.text == "a")
}

@Test func deleteWordThroughInputController() {
    let p = FakeProxy()
    let c = InputController(proxy: p)
    c.insert("hello big world ")
    c.deleteWord()
    #expect(p.text == "hello big ")
}
