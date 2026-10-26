import Testing
import IBoardEngine

@Suite struct SmartPunctuationTests {
    let t = PunctuationTraits()

    func cap(_ s: String, _ m: Autocapitalization = .sentences) -> Bool {
        SmartPunctuation.shouldAutocapitalize(leftContext: s, mode: m)
    }

    func ins(_ text: String, after ctx: String, _ traits: PunctuationTraits? = nil) -> TextEdit {
        SmartPunctuation.edit(forInserting: text, leftContext: ctx, traits: traits ?? t)
    }

    // MARK: capitalization

    @Test func sentencesMode() {
        #expect(cap(""))
        #expect(cap("   "))
        #expect(cap("Hello. "))
        #expect(cap("Really? "))
        #expect(cap("Wow!  "))
        #expect(cap("Hello.\n"))
        #expect(cap("Hello\n"))
        #expect(cap("He said \"stop.\" "))
        #expect(cap("(Done.) "))
        #expect(cap("Wait… "))
        #expect(!cap("Hello."))
        #expect(!cap("Hello "))
        #expect(!cap("Hello, "))
        #expect(!cap("hello"))
        #expect(!cap("Hi there"))
    }

    @Test func abbreviationsAndInitialsDoNotCapitalize() {
        #expect(!cap("Hi Mr. "))
        #expect(!cap("Ask Dr. "))
        #expect(!cap("for e.g. "))
        #expect(!cap("that is, i.e. "))
        #expect(!cap("J. "))
        #expect(!cap("the U.S. "))
        #expect(cap("so do I. "))
    }

    @Test func otherModes() {
        #expect(!cap("anything.", .none) && !cap("", .none))
        #expect(cap("x", .allCharacters))
        #expect(cap("", .words) && cap("hello ", .words) && !cap("hello", .words))
        #expect(cap("one\n", .words))
    }

    @Test func emojiAndCombiningMarks() {
        #expect(!cap("Great 😀 "))                      // emoji is not a sentence end
        #expect(cap("Great. 😀\n"))                     // newline wins
        #expect(cap("Voila\u{301}! "))                  // combining accent before the terminator
        #expect(!cap("cafe\u{301} "))
        #expect(cap("👨‍👩‍👧 Family. "))
        #expect(cap("Hello.\u{301} ") == false)         // "." + combining mark is one odd grapheme, not a terminator
    }

    @Test func contextCappedAt500CharactersStillWorks() {
        let filler = String(repeating: "word ", count: 100)            // 500 chars, no sentence end
        #expect(!cap(String(filler.suffix(500))))
        let tail = String((String(repeating: "x", count: 480) + ". ").suffix(500))
        #expect(cap(tail))
        // cut mid-sentence by the cap: the window starts mid-word and has no terminator
        #expect(!cap("ord and more words "))
        // sentence end right at the window start
        #expect(cap(". "))
    }

    // MARK: double space

    @Test func doubleSpaceBecomesPeriod() {
        #expect(ins(" ", after: "Hello ") == TextEdit(deleteBackward: 1, insert: ". "))
        #expect(ins(" ", after: "Hello") == TextEdit(insert: " "))
        #expect(ins(" ", after: "") == TextEdit(insert: " "))
        #expect(ins(" ", after: "Hello. ") == TextEdit(insert: " "))
        #expect(ins(" ", after: "Hello,  ") == TextEdit(insert: " "))
        #expect(ins(" ", after: "Hello, ") == TextEdit(insert: " "))
        #expect(ins(" ", after: "a\n ") == TextEdit(insert: " "))
        #expect(ins(" ", after: "Nice 😀 ") == TextEdit(deleteBackward: 1, insert: ". "))
        #expect(ins(" ", after: "cafe\u{301} ") == TextEdit(deleteBackward: 1, insert: ". "))
        var off = t
        off.doubleSpacePeriod = false
        #expect(ins(" ", after: "Hello ", off) == TextEdit(insert: " "))
    }

    // MARK: quotes

    @Test func smartQuotes() {
        #expect(ins("\"", after: "").insert == "\u{201C}")
        #expect(ins("\"", after: "He said ").insert == "\u{201C}")
        #expect(ins("\"", after: "He said \"hi").insert == "\u{201D}")
        #expect(ins("\"", after: "(").insert == "\u{201C}")
        #expect(ins("\"", after: "word\n").insert == "\u{201C}")
        #expect(ins("\"", after: "Fine 😀").insert == "\u{201D}")
        #expect(ins("'", after: "don").insert == "\u{2019}")
        #expect(ins("'", after: "dogs").insert == "\u{2019}")
        #expect(ins("'", after: "say ").insert == "\u{2018}")
        #expect(ins("'", after: "cafe\u{301}").insert == "\u{2019}")
        #expect(ins("'", after: "1990").insert == "\u{2019}")
        #expect(ins("\"", after: "x").deleteBackward == 0)
    }

    @Test func smartQuotesOffPassesThrough() {
        var off = t
        off.smartQuotes = .no
        #expect(ins("\"", after: "", off) == TextEdit(insert: "\""))
        #expect(ins("'", after: "don", off) == TextEdit(insert: "'"))
        off.smartQuotes = .yes
        #expect(ins("\"", after: "", off).insert == "\u{201C}")
    }

    // MARK: dashes

    @Test func smartDashes() {
        #expect(ins("-", after: "word-") == TextEdit(deleteBackward: 1, insert: "\u{2014}"))
        #expect(ins("-", after: "word") == TextEdit(insert: "-"))
        #expect(ins("-", after: "--") == TextEdit(insert: "-"))
        #expect(ins("-", after: "x\u{2014}") == TextEdit(insert: "-"))
        var off = t
        off.smartDashes = .no
        #expect(ins("-", after: "word-", off) == TextEdit(insert: "-"))
    }

    @Test func otherTextPassesThrough() {
        #expect(ins("a", after: "x") == TextEdit(insert: "a"))
        #expect(ins("😀", after: "x") == TextEdit(insert: "😀"))
    }

    // MARK: contractions

    @Test func wordBeforeCursor() {
        #expect(SmartPunctuation.wordBeforeCursor("hello dont") == "dont")
        #expect(SmartPunctuation.wordBeforeCursor("it's") == "it's")
        #expect(SmartPunctuation.wordBeforeCursor("hello ") == "")
        #expect(SmartPunctuation.wordBeforeCursor("😀cafe\u{301}") == "cafe\u{301}")
        #expect(SmartPunctuation.wordBeforeCursor("") == "")
    }

    @Test func unambiguousContractionsAreAutoApplicable() {
        let d = SmartPunctuation.contraction(forWord: "dont")
        #expect(d == ContractionSuggestion(typed: "dont", replacement: "don't", isAutoApplicable: true))
        #expect(SmartPunctuation.contraction(forWord: "Dont")?.replacement == "Don't")
        #expect(SmartPunctuation.contraction(forWord: "DONT")?.replacement == "DON'T")
        #expect(SmartPunctuation.contraction(forWord: "im")?.replacement == "I'm")
        #expect(SmartPunctuation.contraction(forWord: "Im")?.replacement == "I'm")
    }

    @Test func ambiguousContractionsAreSuggestionsOnly() {
        for w in ["ill", "id", "hes", "shes", "lets", "were", "well", "its", "wont"] {
            let s = SmartPunctuation.contraction(forWord: w)
            #expect(s != nil && s?.isAutoApplicable == false, "\(w)")
        }
        #expect(SmartPunctuation.contraction(forWord: "hello") == nil)
    }

    @Test func lowContextConfidenceDemotesToSuggestion() {
        #expect(SmartPunctuation.contraction(forWord: "dont", contextConfidence: 0.5)?.isAutoApplicable == false)
        #expect(SmartPunctuation.contraction(forWord: "dont", contextConfidence: 1)?.isAutoApplicable == true)
    }
}
