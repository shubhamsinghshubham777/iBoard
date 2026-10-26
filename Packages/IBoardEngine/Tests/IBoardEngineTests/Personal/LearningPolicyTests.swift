import Foundation
import Testing
@testable import IBoardEngine

private struct Env {
    let storage = InMemoryPersonalStorage()
    let clock = ManualPersonalClock()
    let store: PersonalStore
    let learner: PersonalLearner

    init() {
        store = PersonalStore(storage: storage, clock: clock)
        learner = PersonalLearner(store: store, clock: clock)
    }

    /// Nothing was written anywhere (memory, journal, snapshot).
    func isUntouched() async -> Bool {
        let s = await store.stats()
        return storage.snapshotData == nil && storage.journalData.isEmpty
            && s.unigrams == 0 && s.bigrams == 0 && s.trigrams == 0 && s.phrases == 0
    }

    /// Types `words` as typed words then moves on, so every one of them is "kept".
    func type(_ words: [String], source: CommitSource = .typed) async {
        for w in words {
            await learner.typingContinued()
            await learner.wordCommitted(w, source: source)
        }
        await learner.flush()
    }
}

@Suite struct LearningPolicyTests {
    // MARK: Exclusion matrix

    static let excludedContentTypes = [
        "URL", "emailAddress", "username", "password", "newPassword", "oneTimeCode", "creditCardNumber",
        "creditCardSecurityCode", "creditCardExpiration", "creditCardExpirationMonth", "creditCardExpirationYear",
        "creditCardName", "creditCardType", "telephoneNumber", "postalCode", "cellularEID", "cellularIMEI",
        "flightNumber", "shipmentTrackingNumber", "EMAILADDRESS",
    ]
    static let allowedContentTypes: [String?] = [
        nil, "", "name", "givenName", "familyName", "nickname", "streetAddressLine1", "addressCity", "location",
        "organizationName", "jobTitle", "fullStreetAddress", "someFutureContentType",
    ]
    // UIKeyboardType 0...11 with expected exclusion.
    static let keyboardExpectation: [(Int, Bool)] = [
        (0, false), (1, false), (2, false), (3, true), (4, true), (5, true), (6, true), (7, true), (8, true),
        (9, false), (10, false), (11, true),
    ]

    @Test func contentTypeMatrix() {
        for raw in Self.excludedContentTypes {
            #expect(FieldContentType(rawValue: raw).isExcluded, "\(raw)")
            #expect(FieldTraits(contentType: .init(rawValue: raw)).exclusion == .contentType, "\(raw)")
        }
        for raw in Self.allowedContentTypes {
            #expect(!FieldContentType(rawValue: raw).isExcluded, "\(String(describing: raw))")
        }
    }

    @Test func keyboardTypeMatrix() {
        for (raw, excluded) in Self.keyboardExpectation {
            let kind = FieldKeyboardKind(uikitRawValue: raw)
            #expect(kind.isExcluded == excluded, "keyboardType \(raw)")
            #expect((FieldTraits(keyboardType: kind).exclusion != nil) == excluded)
        }
        #expect(!FieldKeyboardKind(uikitRawValue: 999).isExcluded)  // unknown -> default
    }

    @Test func secureEntryAlwaysExcluded() {
        for (raw, _) in Self.keyboardExpectation {
            let t = FieldTraits(keyboardType: .init(uikitRawValue: raw), isSecureTextEntry: true)
            #expect(t.exclusion == .secureEntry)
        }
    }

    @Test func fullCrossProductExclusionDecision() {
        for ct in Self.excludedContentTypes.map({ Optional($0) }) + Self.allowedContentTypes {
            for (kb, kbEx) in Self.keyboardExpectation {
                for secure in [false, true] {
                    let t = FieldTraits(contentType: .init(rawValue: ct), keyboardType: .init(uikitRawValue: kb),
                                        isSecureTextEntry: secure)
                    let ctEx = FieldContentType(rawValue: ct).isExcluded
                    #expect((t.exclusion != nil) == (secure || ctEx || kbEx))
                }
            }
        }
    }

    @Test func nothingIsLearnedInAnyExcludedField() async {
        var combos: [FieldTraits] = []
        for ct in Self.excludedContentTypes { combos.append(FieldTraits(contentType: .init(rawValue: ct))) }
        for (kb, ex) in Self.keyboardExpectation where ex { combos.append(FieldTraits(keyboardType: .init(uikitRawValue: kb))) }
        combos.append(FieldTraits(isSecureTextEntry: true))
        combos.append(FieldTraits(contentType: .init(rawValue: "password"), keyboardType: .url, isSecureTextEntry: true))
        for traits in combos {
            let env = Env()
            await env.learner.fieldDidChange(traits)
            #expect(await !env.learner.isLearning)
            await env.type(["hello", "wonderful", "shubham", "meeting", "tomorrow"])
            await env.learner.autocorrectReverted(original: "wonderful")
            await env.learner.sentenceBoundary()
            await env.learner.typingContinued()
            await env.learner.flush()
            #expect(await env.isUntouched(), "\(traits)")
        }
    }

    @Test func allowedFieldsLearnPositiveControl() async {
        var combos: [FieldTraits] = [.default]
        for ct in Self.allowedContentTypes { combos.append(FieldTraits(contentType: .init(rawValue: ct))) }
        for (kb, ex) in Self.keyboardExpectation where !ex { combos.append(FieldTraits(keyboardType: .init(uikitRawValue: kb))) }
        for traits in combos {
            let env = Env()
            await env.learner.fieldDidChange(traits)
            await env.type(["wonderful"])
            #expect(await env.store.uses(of: "wonderful") == 1, "\(traits)")
        }
    }

    @Test func failsClosedBeforeFirstFieldEvent() async {
        let env = Env()
        await env.type(["wonderful", "meeting"])
        #expect(await env.isUntouched())
    }

    @Test func switchingIntoExcludedFieldDiscardsPendingWords() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.learner.wordCommitted("secret", source: .typed)      // pending
        await env.learner.fieldDidChange(FieldTraits(contentType: .init(rawValue: "password")))
        await env.learner.typingContinued()
        await env.learner.flush()
        await env.learner.fieldDidChange(.default)
        await env.learner.flush()
        // "secret" was pending when the field changed: a field change flushes the OLD field (it was learnable there).
        #expect(await env.store.uses(of: "secret") == 1)
        // But words typed inside the excluded field never are.
        await env.learner.fieldDidChange(FieldTraits(isSecureTextEntry: true))
        await env.type(["hidden"])
        await env.learner.fieldDidChange(.default)
        #expect(await env.store.uses(of: "hidden") == 0)
    }

    // MARK: Incognito

    @Test func zeroLearningWhileIncognito() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.learner.setIncognito(true)
        #expect(await env.learner.incognito.indicator == .manual)
        await env.type(["alpha", "bravo", "charlie", "delta"])
        await env.learner.wordCommitted("echo", source: .suggestionTapped)
        await env.learner.autocorrectReverted(original: "foxtrot")
        await env.learner.sentenceBoundary()
        await env.learner.fieldDidChange(.default)
        await env.learner.flush()
        #expect(await env.isUntouched())
        await env.learner.setIncognito(false)
        await env.type(["golf"])
        #expect(await env.store.uses(of: "golf") == 1)
    }

    @Test func togglingIncognitoOnDropsPendingWords() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.learner.wordCommitted("private", source: .typed)
        await env.learner.setIncognito(true)
        await env.learner.setIncognito(false)
        await env.learner.flush()
        #expect(await env.isUntouched())
    }

    @Test func incognitoStateModel() {
        var s = IncognitoState()
        #expect(!s.isActive && s.indicator == .off)
        s.fieldChanged(FieldTraits(contentType: .init(rawValue: "oneTimeCode")))
        #expect(s.isActive && s.indicator == .automatic(.contentType))
        s.setUserToggle(true)
        #expect(s.indicator == .manual)
        s.fieldChanged(.default)
        #expect(s.isActive && s.indicator == .manual)
        s.toggle()
        #expect(!s.isActive && s.indicator == .off)
        s.fieldChanged(FieldTraits(keyboardType: .url))
        #expect(s.indicator == .automatic(.keyboardType))
        s.fieldChanged(FieldTraits(isSecureTextEntry: true))
        #expect(s.indicator == .automatic(.secureEntry))
    }

    // MARK: Word filter

    @Test func wordFilterTable() {
        let ok = ["hello", "don't", "it\u{2019}s", "well-known", "iPhone", "McDonald", "NASA", "Shubham", "café", "namaste",
                  "kya", "rhythm", "सुंदर", "ok", "YouTube", "hmm"]
        for w in ok { #expect(LearnableWord.rejection(w) == nil, "\(w)") }
        let bad: [(String, LearnableWord.Rejection)] = [
            ("a", .tooShort), ("", .tooShort), (String(repeating: "x", count: 33), .tooLong),
            ("abc123", .containsDigit), ("123456", .containsDigit), ("2nd", .containsDigit), ("४५६", .containsDigit),
            ("me@example", .looksLikeEmail), ("user@x.com", .looksLikeEmail),
            ("example.com", .looksLikeURL), ("https://x", .looksLikeURL), ("a/b", .looksLikeURL), ("www", .looksLikeURL),
            ("wwwfoo", .looksLikeURL), ("C:\\x", .looksLikeURL),
            ("hello!", .invalidCharacters), ("-word", .invalidCharacters), ("word-", .invalidCharacters),
            ("a_b", .invalidCharacters), ("#tag", .invalidCharacters), ("😀😀", .invalidCharacters),
            ("aBcDe", .looksLikeCode), ("sooooo", .looksLikeCode), ("deadbeef", .looksLikeCode),
            ("hmmmmm", .looksLikeCode), ("qwrtp", .looksLikeCode),
        ]
        for (w, r) in bad { #expect(LearnableWord.rejection(w) == r, "\(w)") }
    }

    @Test func codesNumbersAndURLsAreNeverLearnedEvenInNormalFields() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.type(["123456", "abc123", "https://example.com", "me@x.com", "example.com", "a1b2c3d4", "deadbeef"])
        #expect(await env.isUntouched())
    }

    @Test func barrierWordsBreakNgramContext() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.type(["call", "123456", "tomorrow"])
        let st = await env.store.exportState()
        #expect(st.bigrams.isEmpty)   // no (call,123456), (123456,tomorrow) and no (call,tomorrow)
        #expect(st.unigrams.count == 2)
    }

    // MARK: Kept-word detection

    @Test func wordIsLearnedOnlyOnceKept() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.learner.wordCommitted("shubham", source: .typed)
        #expect(await env.store.uses(of: "shubham") == 0)          // not yet kept
        await env.learner.typingContinued()                          // user typed the next character
        #expect(await env.store.uses(of: "shubham") == 1)
        let c = await env.store.scorer().completions(prefix: "sh", limit: 3)
        #expect(c.map(\.word) == ["shubham"])
    }

    @Test func reopenedWordIsNotLearned() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.learner.wordCommitted("teh", source: .typed)
        await env.learner.lastWordReopened()                         // backspace into the word
        await env.learner.typingContinued()
        await env.learner.flush()
        #expect(await env.isUntouched())
    }

    @Test func revertedAutocorrectDropsCorrectionAndLearnsOriginalDeliberately() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.learner.wordCommitted("duck", source: .autocorrected)
        await env.learner.autocorrectReverted(original: "ducking")
        await env.learner.typingContinued()
        #expect(await env.store.uses(of: "duck") == 0)
        #expect(await env.store.uses(of: "ducking") == 1)
        #expect(abs(await env.store.effectiveWeight(of: "ducking") - 1.0) < 1e-6)  // restored original: strong
    }

    @Test func weightGrowsWithUse() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        var weights: [Double] = []
        for _ in 0..<4 {
            await env.type(["zorblax"])
            weights.append(await env.store.effectiveWeight(of: "zorblax"))
        }
        #expect(abs(weights[0] - 0.3) < 1e-5)
        #expect(abs(weights[1] - 1.0) < 1e-5)
        #expect(abs(weights[2] - 2.0) < 1e-5)
        #expect(abs(weights[3] - 3.0) < 1e-5)
    }

    @Test func casingKeptForProperNounsNotSentenceStart() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.type(["Hello", "Shubham", "and", "iPhone"])
        let st = await env.store.exportState()
        #expect(st.surfaces["hello"] == nil)
        #expect(st.surfaces["shubham"] == "Shubham")
        #expect(st.surfaces["iphone"] == "iPhone")
    }

    @Test func ngramsAndPhrasesLearnedWithinSentenceOnly() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        for _ in 0..<2 {
            await env.type(["see", "you", "at", "lunch"])
            await env.learner.sentenceBoundary()
        }
        let st = await env.store.exportState()
        #expect(st.bigrams["you\u{1F}at"] != nil)
        #expect(st.trigrams["see\u{1F}you\u{1F}at"] != nil)
        #expect(st.bigrams["lunch\u{1F}see"] == nil)       // no n-gram across the sentence boundary
        let phrases = await env.store.repeatedPhrases()
        #expect(phrases.contains(["see", "you", "at", "lunch"]))
        #expect(phrases.contains(["you", "at", "lunch"]))
        #expect(phrases.allSatisfy { (3...6).contains($0.count) })
    }

    // MARK: Forget semantics

    @Test func forgottenWordIsNotRelearnedWithinThirtyDays() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.type(["zorblax"])
        await env.learner.forgetSuggestion("zorblax")
        #expect(await env.store.uses(of: "zorblax") == 0)
        #expect(await env.store.isForgotten("zorblax"))
        await env.type(["zorblax"], source: .suggestionTapped)
        env.clock.advance(days: 29)
        await env.type(["zorblax"], source: .swipe)
        #expect(await env.store.uses(of: "zorblax") == 0)
        #expect(await env.store.isForgotten("zorblax"))
    }

    @Test func forgottenWordIsRelearnedAfterThirtyDays() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.type(["zorblax"])
        await env.learner.forgetSuggestion("zorblax")
        env.clock.advance(days: 30.01)
        await env.type(["zorblax"], source: .suggestionTapped)
        #expect(await env.store.uses(of: "zorblax") == 1)
        #expect(await !env.store.isForgotten("zorblax"))
    }

    @Test func forgottenWordReturnsAfterThreeDeliberateRetypes() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.type(["zorblax"])
        await env.learner.forgetSuggestion("zorblax")
        await env.type(["zorblax"])
        #expect(await env.store.uses(of: "zorblax") == 0)
        await env.type(["zorblax"])
        #expect(await env.store.uses(of: "zorblax") == 0)
        #expect(await env.store.forgetEntry(for: "zorblax")?.deliberate == 2)
        await env.type(["zorblax"])                                  // third deliberate retype
        #expect(await env.store.uses(of: "zorblax") == 1)
        #expect(await !env.store.isForgotten("zorblax"))
    }

    @Test func forgetRemovesNgramsContainingWord() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.type(["see", "zorblax", "now"])
        await env.learner.forgetSuggestion("zorblax")
        let st = await env.store.exportState()
        #expect(st.bigrams.keys.allSatisfy { !$0.contains("zorblax") })
        #expect(st.trigrams.isEmpty)
        #expect(st.unigrams["see"] != nil && st.unigrams["now"] != nil)
    }

    @Test func forgottenWordInLearnedSentenceBreaksContext() async {
        let env = Env()
        await env.learner.fieldDidChange(.default)
        await env.type(["zorblax"])
        await env.learner.forgetSuggestion("zorblax")
        await env.learner.sentenceBoundary()
        await env.type(["see", "zorblax", "now"])    // zorblax skipped (not deliberate? typed = deliberate #1 of 3)
        let st = await env.store.exportState()
        #expect(st.bigrams["see\u{1F}now"] == nil)
        #expect(st.unigrams["zorblax"] == nil)
    }
}
