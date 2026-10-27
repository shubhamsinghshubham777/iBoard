import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

/// English small fixture + synthetic Hinglish fixture (Fixtures/hinglish-small).
struct DualLanguage {
    let en: Lexicon
    let enLM: NGramModel
    let hi: Lexicon
    let hiLM: NGramModel
    var secondary: SecondaryLanguage { SecondaryLanguage(lexicon: hi, model: hiLM) }

    init() throws {
        en = try Fixture.small.lexicon()
        enLM = try Fixture.small.model(lexicon: en)
        hi = try Fixture.hinglish.lexicon()
        hiLM = try Fixture.hinglish.model(lexicon: hi)
    }

    func decoder(codeSwitch: CodeSwitchParameters = CodeSwitchParameters(), dual: Bool = true) -> TapDecoder {
        TapDecoder(layout: testLayout, lexicon: en, model: enLM, secondary: dual ? secondary : nil, codeSwitch: codeSwitch)
    }

    /// Hinglish words (3+ letters) that are not English words.
    var hinglishOnly: [String] {
        (0..<hi.wordCount).map { hi.word(of: UInt32($0)) }
            .filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLetter } && en.lookup($0) == nil }
    }

    func context(_ previous: [String], bias: Double = 0, params: CodeSwitchParameters = CodeSwitchParameters())
        -> (primary: LMContext, secondary: SecondaryContext) {
        CodeSwitch.context(previousWords: previous, primary: en, secondary: secondary, parameters: params, personalBias: bias)
    }
}

/// Point between two letter keys: `t` = 0 is the centre of `a`, 1 the centre of `b`.
func between(_ a: Character, _ b: Character, _ t: Double) -> CGPoint {
    let p = centre(a), q = centre(b)
    return CGPoint(x: p.x + (q.x - p.x) * CGFloat(t), y: p.y + (q.y - p.y) * CGFloat(t))
}

@Suite struct CodeSwitchContextTests {
    let d: DualLanguage
    init() throws { d = try DualLanguage() }

    @Test func fixtureShape() {
        #expect(d.hi.wordCount > 100)
        #expect(d.hi.lookup("nhi") != nil && d.hi.lookup("nahin") != nil && d.hi.lookup("kya") != nil)
        #expect(d.en.lookup("nhi") == nil && d.en.lookup("go") != nil && d.hi.lookup("go") == nil)
    }

    @Test func languageEvidenceFromPreviousWords() {
        let hinglish = d.context(["kya", "haal"]).secondary.logOdds
        let english = d.context(["good", "morning"]).secondary.logOdds   // both Hinglish-fixture words too: neutral...
        let pureEnglish = d.context(["the", "people"]).secondary.logOdds
        #expect(hinglish > 1.5, "\(hinglish)")
        #expect(pureEnglish < -1.5, "\(pureEnglish)")
        #expect(abs(english) < 0.01 || english < 0, "both-lexicon words add no Hinglish evidence: \(english)")
        #expect(d.context([]).secondary.logOdds == 0)
        // A word in both lexicons ("meeting") and an unknown word are neutral.
        #expect(d.context(["meeting"]).secondary.logOdds == 0)
        #expect(d.context(["qzxqz"]).secondary.logOdds == 0)
    }

    @Test func recentWordsCountMoreAndEvidenceIsCapped() {
        let recentHinglish = d.context(["people", "kya"]).secondary.logOdds
        let recentEnglish = d.context(["kya", "people"]).secondary.logOdds
        #expect(recentHinglish > 0 && recentEnglish < 0 && recentHinglish == -recentEnglish)
        var p = CodeSwitchParameters()
        p.maxLogOdds = 2
        let capped = d.context(["kya", "hai", "nahi", "kuch", "aur"], params: p).secondary.logOdds
        #expect(capped == 2)
        #expect(d.context(["the", "people", "world", "family", "dinner"], params: p).secondary.logOdds == -2)
    }

    @Test func priorsAreAProbabilityDistribution() {
        for odds in [-3.0, -0.4, 0, 1.3, 3.0] {
            let c = SecondaryContext(logOdds: odds)
            let total = exp(c.logPrior(.primary)) + exp(c.logPrior(.secondary))
            #expect(abs(total - 1) < 1e-12)
        }
        #expect(SecondaryContext(logOdds: 0).logPrior(.primary) == SecondaryContext(logOdds: 0).logPrior(.secondary))
    }

    @Test func contextIdsArePerLexicon() throws {
        let c = d.context(["kya", "hai"])
        #expect(c.secondary.lm.older == d.hi.lookup("kya") && c.secondary.lm.recent == d.hi.lookup("hai"))
        #expect(c.primary.older == nil && c.primary.recent == nil)   // neither is an English word
        let e = d.context(["the", "meeting"])
        #expect(e.primary.older == d.en.lookup("the") && e.primary.recent == d.en.lookup("meeting"))
        #expect(e.secondary.lm.older == nil && e.secondary.lm.recent == d.hi.lookup("meeting"))
    }
}

/// Personal model stub: fixed word weights.
struct StubPersonal: PersonalScoreProvider {
    var words: [String: Double]
    func score(word: String, context: [String]) -> PersonalScore? {
        words[word].map { PersonalScore(probability: min(0.9, $0 / 100), weight: 0.3) }
    }
    func completions(prefix: String, limit: Int) -> [PersonalCompletion] {
        var out: [PersonalCompletion] = []
        for (word, weight) in words where word.hasPrefix(prefix) {
            out.append(PersonalCompletion(word: word, weight: weight))
        }
        out.sort { (a: PersonalCompletion, b: PersonalCompletion) -> Bool in
            a.weight != b.weight ? a.weight > b.weight : a.word < b.word
        }
        return Array(out.prefix(limit))
    }
    func isForgotten(_ word: String) -> Bool { false }
    func isNeverCorrect(_ word: String) -> Bool { false }
}

@Suite struct CodeSwitchPersonalBiasTests {
    let d: DualLanguage
    init() throws { d = try DualLanguage() }

    private func bias(_ words: [String: Double]) -> Double {
        CodeSwitch.personalBias(from: StubPersonal(words: words), primary: d.en, secondary: d.secondary,
                                parameters: CodeSwitchParameters())
    }

    @Test func leansToTheLanguageOfTheLearnedWords() {
        #expect(bias(["yaar": 60, "bhai": 50, "kaam": 40, "ghar": 30]) > 0.5)
        #expect(bias(["people": 60, "family": 50, "world": 40, "dinner": 30]) < -0.5)
        #expect(abs(bias(["yaar": 50, "people": 50])) < 0.01)
    }

    @Test func tinyVocabulariesAndNeutralWordsBarelyMove() {
        #expect(abs(bias([:])) == 0)
        #expect(abs(bias(["yaar": 1])) < 0.2)
        #expect(abs(bias(["meeting": 500, "qzxqz": 500])) == 0)     // both-lexicon and unknown words
        #expect(bias(["yaar": 5000, "bhai": 5000]) <= CodeSwitchParameters().maxPersonalBias)
    }

    @Test func personalWeightZeroDisablesIt() {
        var p = CodeSwitchParameters()
        p.personalWeight = 0
        #expect(CodeSwitch.personalBias(from: StubPersonal(words: ["yaar": 60]), primary: d.en, secondary: d.secondary,
                                        parameters: p) == 0)
    }

    @Test func biasShiftsTheContextOdds() {
        #expect(d.context([], bias: 1.2).secondary.logOdds == 1.2)
        #expect(d.context(["kya"], bias: -1).secondary.logOdds < d.context(["kya"]).secondary.logOdds)
    }
}

@Suite struct DualTapDecoderTests {
    let d: DualLanguage
    init() throws { d = try DualLanguage() }

    @Test func withoutSecondaryTheDecoderIsUnchanged() {
        let single = d.decoder(dual: false)
        let plain = TapDecoder(layout: testLayout, lexicon: d.en, model: d.enLM)
        for w in ["hello", "world", "going", "tomorrow", "the", "weekend"] {
            let a = single.decode(points: w.map(centre))
            let b = plain.decode(points: w.map(centre))
            #expect(a == b)
            #expect(a.candidates.allSatisfy { $0.side == .primary && $0.languagePrior == 0 })
        }
    }

    @Test func englishWordsStillDecodeWithTheSecondLanguageOn() {
        let dual = d.decoder()
        for w in ["hello", "world", "going", "tomorrow", "people", "family", "yesterday"] {
            let r = dual.decode(points: w.map(centre), context: .none, secondaryContext: SecondaryContext())
            #expect(r.candidates.first?.word == w, "\(w) -> \(r.candidates.map(\.word))")
            #expect(r.autocorrect == nil)
            #expect(r.candidates.first?.side == .primary)
        }
    }

    @Test func hinglishWordsDecodeAndAreMarkedSecondary() {
        let dual = d.decoder()
        let single = d.decoder(dual: false)
        let words = d.hinglishOnly
        #expect(words.count > 60)
        var wrong: [String] = []
        for w in words {
            let r = dual.decode(points: w.map(centre))
            if r.candidates.first?.word != w || r.candidates.first?.side != .secondary { wrong.append(w) }
            #expect(r.autocorrect == nil, "\(w)")
            #expect(r.candidates.first?.wordID == d.hi.lookup(w))
            // The English-only decoder cannot know the word.
            #expect(single.decode(points: w.map(centre)).candidates.first { $0.isLiteral }?.wordID == nil)
        }
        #expect(Double(wrong.count) / Double(words.count) < 0.03, "wrong: \(wrong)")
    }

    @Test func variantSpellingsAreAllValidLiterals() {
        let dual = d.decoder()
        for w in ["nahi", "nhi", "nahin", "kya", "kyaa", "hai", "hain", "kyu", "kyun", "accha", "acha", "achha"] {
            guard d.hi.lookup(w) != nil else { continue }
            let r = dual.decode(points: w.map(centre))
            #expect(r.literal == w)
            #expect(r.candidates.first?.word == w, "\(w) -> \(r.candidates.map(\.word))")
            #expect(r.autocorrect == nil && r.literalPosterior > 0.5, "\(w)")
        }
    }

    @Test func sloppyHinglishTapIsCorrectedToHinglish() throws {
        // "nahi" with the 'i' landing 70% toward 'o': literal "naho" is nothing.
        var pts = "nahi".map(centre)
        pts[3] = between("i", "o", 0.7)
        let dual = d.decoder().decode(points: pts)
        #expect(dual.literal == "naho")
        #expect(dual.candidates.first?.word == "nahi")
        #expect(dual.autocorrect?.word == "nahi" && dual.autocorrect?.side == .secondary)
        #expect(dual.autocorrectConfidence > 0.8, "\(dual.autocorrectConfidence)")
        #expect(d.decoder(dual: false).decode(points: pts).autocorrect?.word != "nahi")
    }

    @Test func completionsComeFromBothLanguages() {
        let r = d.decoder().decode(points: "ka".map(centre))
        let sides = Set(r.candidates.filter(\.isCompletion).map(\.side))
        let words = r.candidates.map(\.word)
        #expect(words.contains("kaam"), "\(words)")
        let t = d.decoder().decode(points: "th".map(centre))
        #expect(t.candidates.contains { $0.word == "the" } && t.candidates.contains { $0.word == "thik" || $0.word == "theek" || $0.word == "thanks" },
                "\(t.candidates.map(\.word))")
        _ = sides
        // No duplicates by word text across the two lexicons.
        for res in [r, t] { #expect(Set(res.candidates.map(\.word)).count == res.candidates.count) }
    }

    @Test func wordInBothLexiconsAppearsOnce() {
        let r = d.decoder().decode(points: "meeting".map(centre))
        #expect(r.candidates.filter { $0.word == "meeting" }.count == 1)
        #expect(r.candidates.first?.word == "meeting" && r.autocorrect == nil)
    }

    @Test func deterministic() {
        let dual = d.decoder()
        var pts = "kya".map(centre)
        pts[1] = between("y", "u", 0.45)
        let ctx = d.context(["bhai"])
        let a = dual.decode(points: pts, context: ctx.primary, secondaryContext: ctx.secondary)
        let b = dual.decode(points: pts, context: ctx.primary, secondaryContext: ctx.secondary)
        #expect(a == b)
    }

    // MARK: Language context

    @Test func languageContextBreaksTiesBetweenTheTwoLanguages() {
        // Touches half way between 'g' and 'h' then 'o': English "go" or Hinglish "ho".
        let pts = [between("g", "h", 0.5), centre("o")]
        let dual = d.decoder()
        // (Words with no n-grams in either fixture, so only the language prior differs.)
        let hinglishCtx = d.context(["dost", "subah"])
        let englishCtx = d.context(["people", "family"])
        let h = dual.decode(points: pts, context: hinglishCtx.primary, secondaryContext: hinglishCtx.secondary)
        let e = dual.decode(points: pts, context: englishCtx.primary, secondaryContext: englishCtx.secondary)
        let hs = h.candidates.first { $0.word == "ho" }!.score - h.candidates.first { $0.word == "go" }!.score
        let es = e.candidates.first { $0.word == "ho" }!.score - e.candidates.first { $0.word == "go" }!.score
        #expect(hs > es + 3, "Hinglish context favours ho by \(hs), English context by \(es)")
        #expect(h.candidates.first?.word == "ho", "\(h.candidates.map(\.word))")
        #expect(es < 0, "English context prefers go over ho by \(-es)")
    }

    @Test func priorWeightZeroDropsTheContextEffect() {
        var p = CodeSwitchParameters()
        p.priorWeight = 0
        let pts = [between("g", "h", 0.5), centre("o")]
        let dual = d.decoder(codeSwitch: p)
        let ra = dual.decode(points: pts, secondaryContext: SecondaryContext(logOdds: 3))
        let rb = dual.decode(points: pts, secondaryContext: SecondaryContext(logOdds: -3))
        #expect(ra == rb)
        #expect(dual.decode(points: pts, secondaryContext: SecondaryContext(logOdds: 3)) != d.decoder().decode(
            points: pts, secondaryContext: SecondaryContext(logOdds: 3)))
        #expect(ra.candidates.allSatisfy { $0.languagePrior == 0 })
    }

    // MARK: M7-03 protection

    /// "ne" (Hinglish) with the 'n' touch pulled toward 'b' / 'h': English "be" / "he" would win on frequency.
    private var pullTowardEnglish: [CGPoint] { [between("n", "b", 0.45), centre("e")] }

    @Test func validHinglishLiteralIsNeverAutocorrectedIntoEnglish() {
        var off = CodeSwitchParameters()
        off.protectSecondaryWords = false
        let pts = pullTowardEnglish
        // Without the protection rule the English word wins: the rule matters.
        let unprotected = d.decoder(codeSwitch: off).decode(points: pts)
        #expect(unprotected.literal == "ne")
        #expect(unprotected.autocorrect?.word == "be" || unprotected.autocorrect?.word == "he",
                "needs an English top reading to make this test meaningful: \(unprotected.candidates.map(\.word))")
        #expect(!unprotected.literalProtected)
        // With it, no autocorrect, and the protection is reported.
        let protected = d.decoder().decode(points: pts)
        #expect(protected.literal == "ne")
        #expect(protected.autocorrect == nil && protected.autocorrectConfidence == 0)
        #expect(protected.literalProtected)
        // The strip can still offer the English word as a suggestion.
        #expect(protected.candidates.contains { $0.word == "be" || $0.word == "he" })
        // An English-only decoder treats "ne" as a plain typo, as before.
        #expect(d.decoder(dual: false).decode(points: pts).autocorrect != nil)
    }

    @Test func protectionOnlyBlocksCorrectionsIntoEnglishOnlyWords() {
        // Typo that is not a Hinglish word: English correction stays allowed with the second language on.
        var pts = "hello".map(centre)
        pts[3] = between("l", "k", 0.7)
        let r = d.decoder().decode(points: pts)
        #expect(r.literal == "helko")
        #expect(r.autocorrect?.word == "hello" && !r.literalProtected)
        // Hinglish correction target is not blocked either (see sloppyHinglishTapIsCorrectedToHinglish).
    }

    @Test func protectionHelper() {
        let s = d.secondary
        #expect(CodeSwitch.isProtected(literal: "ne", target: "be", secondary: s))
        #expect(!CodeSwitch.isProtected(literal: "ne", target: "ke", secondary: s))      // target is Hinglish
        #expect(!CodeSwitch.isProtected(literal: "qzxqz", target: "be", secondary: s))   // literal is not a Hinglish word
        #expect(!CodeSwitch.isProtected(literal: "ne", target: "me", secondary: s))      // "me" exists in both
    }
}

@Suite struct DualEngineActorTests {
    let d: DualLanguage
    init() throws { d = try DualLanguage() }

    private func engine(dual: Bool = true, personal: (any PersonalScoreProvider)? = nil,
                        params: CodeSwitchParameters = CodeSwitchParameters()) -> EngineActor {
        EngineActor(layout: testLayout, lexicon: d.en, model: d.enLM, personal: personal,
                    secondary: dual ? d.secondary : nil, codeSwitch: params)
    }

    private func request(_ e: EngineActor, _ pts: [CGPoint], previous: [String] = []) -> EngineRequest {
        EngineRequest(sequence: e.beginRequest(), touches: .points(pts), previousWords: previous)
    }

    @Test func hinglishWordTypedExactlyIsAValidLiteral() async throws {
        let e = engine()
        let s = try #require(await e.submit(request(e, "nahi".map(centre), previous: ["pata"])))
        #expect(s.literal == "nahi")
        #expect(s.slots[0].role == .literal && !s.slots[0].showsQuotes)
        #expect(s.slots[0].side == .secondary && s.slots[0].wordID == d.hi.lookup("nahi"))
        #expect(s.autocorrect == nil)
    }

    @Test func sloppyHinglishWordGetsAHinglishProposal() async throws {
        var pts = "nahi".map(centre)
        pts[3] = between("i", "o", 0.7)
        let e = engine()
        let s = try #require(await e.submit(request(e, pts, previous: ["pata"])))
        #expect(s.literal == "naho")
        #expect(s.autocorrect?.word == "nahi" && s.slots.contains { $0.text == "nahi" && $0.side == .secondary })
        let single = engine(dual: false)
        let t = try #require(await single.submit(request(single, pts, previous: ["pata"])))
        #expect(t.autocorrect?.word != "nahi")
    }

    @Test func validHinglishWordIsNotAutocorrectedIntoEnglishByTheEngine() async throws {
        let pts: [CGPoint] = [between("n", "b", 0.45), centre("e")]
        let e = engine()
        let s = try #require(await e.submit(request(e, pts, previous: ["kya"])))
        #expect(s.literal == "ne" && s.autocorrect == nil)
        #expect(s.slots[0].showsQuotes == false)   // the literal is a valid word
        // With the protection switched off the same input is corrected to English.
        var off = CodeSwitchParameters()
        off.protectSecondaryWords = false
        let e2 = engine(params: off)
        let t = try #require(await e2.submit(request(e2, pts, previous: ["kya"])))
        #expect(t.autocorrect != nil)
        // And the policy never applies anything when there is no proposal.
        let decision = AutocorrectPolicy.decide(literal: s.literal, proposal: s.autocorrect, traits: AutocorrectTraits(),
                                                state: AutocorrectState())
        #expect(decision == .keepLiteral(.noProposal))
    }

    @Test func personalModelKeepsProtectionAndBias() async throws {
        let personal = StubPersonal(words: ["yaar": 60, "bhai": 50, "kaam": 40])
        let e = engine(personal: personal)
        #expect(await e.personalLanguageBias > 0.5)
        let pts: [CGPoint] = [between("n", "b", 0.45), centre("e")]
        let s = try #require(await e.submit(request(e, pts, previous: ["kya"])))
        #expect(s.autocorrect == nil)
        await e.setPersonal(scorer: nil)
        #expect(await e.personalLanguageBias == 0)
    }

    @Test func nextWordPredictionOffersHinglishAfterHinglish() async throws {
        let e = engine()
        let after = try #require(await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points([]),
                                                              previousWords: ["kya", "haal"])))
        #expect(after.slots.first?.text == "hai", "\(after.slots.map(\.text))")
        #expect(after.slots.first?.side == .secondary)
        // Words in both lexicons ("meeting", "to") are offered once.
        let en = try #require(await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points([]),
                                                           previousWords: ["people", "family"])))
        #expect(Set(en.slots.map(\.text)).count == en.slots.count)
        let hi = try #require(await e.submit(EngineRequest(sequence: e.beginRequest(), touches: .points([]),
                                                           previousWords: ["dost", "subah"])))
        let hinglishSlots = { (s: Suggestions) in s.slots.filter { $0.side == .secondary }.count }
        #expect(hinglishSlots(hi) >= hinglishSlots(en), "Hinglish history \(hi.slots.map(\.text)) vs English \(en.slots.map(\.text))")
    }

    @Test func singleLanguageEngineIsUnchanged() async throws {
        let plain = EngineActor(layout: testLayout, lexicon: d.en, model: d.enLM)
        let e = engine(dual: false)
        for w in ["hello", "tomorrow"] {
            let a = try #require(await plain.submit(request(plain, w.map(centre), previous: ["good"])))
            let b = try #require(await e.submit(request(e, w.map(centre), previous: ["good"])))
            #expect(a.slots.map(\.text) == b.slots.map(\.text) && a.autocorrect == b.autocorrect)
        }
    }
}

@Suite struct DualSwipeDecoderTests {
    let d: DualLanguage
    init() throws { d = try DualLanguage() }

    private func decoder(dual: Bool = true) -> SwipeDecoder {
        SwipeDecoder(layout: testLayout, lexicon: d.en, model: d.enLM, secondary: dual ? d.secondary : nil)
    }

    @Test func hinglishSwipesDecodeWhenTheSecondLanguageIsOn() {
        let dual = decoder(), single = decoder(dual: false)
        var wrong: [String] = []
        let words = d.hinglishOnly.filter { $0.count >= 4 }
        for w in words {
            let r = dual.decode(points: centreSwipe(w))
            if r.candidates.first?.word != w || r.candidates.first?.side != .secondary { wrong.append(w) }
            #expect(single.decode(points: centreSwipe(w)).candidates.first?.word != w)
        }
        #expect(Double(wrong.count) / Double(words.count) < 0.2, "wrong: \(wrong)")
    }

    @Test func englishSwipesStayEnglish() {
        let dual = decoder(), single = decoder(dual: false)
        for w in ["hello", "world", "tomorrow", "people", "friend", "morning"] {
            let a = dual.decode(points: centreSwipe(w)), b = single.decode(points: centreSwipe(w))
            #expect(a.candidates.first?.word == b.candidates.first?.word, "\(w)")
            #expect(a.candidates.first?.side == .primary)
        }
    }

    @Test func languageContextReordersAmbiguousSwipes() {
        // A swipe that fits both an English and a Hinglish word equally: use a word in both lexicons with a
        // different neighbour: the context prior should move the Hinglish candidate up with Hinglish history.
        let dual = decoder()
        let pts = centreSwipe("kaam")
        let hCtx = d.context(["dost", "subah"]), eCtx = d.context(["people", "family"])
        let h = dual.decode(points: pts, context: hCtx.primary, contextWords: ["dost", "subah"], secondaryContext: hCtx.secondary)
        let e = dual.decode(points: pts, context: eCtx.primary, contextWords: ["people", "family"], secondaryContext: eCtx.secondary)
        #expect(h.candidates.first?.word == "kaam")
        let hScore = h.candidates.first { $0.word == "kaam" }!.score
        let eScore = e.candidates.first { $0.word == "kaam" }?.score ?? -.infinity
        #expect(hScore > eScore + 1.5, "\(hScore) vs \(eScore)")
    }

    @Test func wordsInBothLexiconsAreNotDuplicated() {
        let r = decoder().decode(points: centreSwipe("meeting"))
        #expect(r.candidates.filter { $0.word == "meeting" }.count == 1)
    }

    @Test func deterministic() {
        let dual = decoder()
        #expect(dual.decode(points: centreSwipe("nahi")) == dual.decode(points: centreSwipe("nahi")))
    }
}

/// Real Hinglish artifacts (Data/hinglish) when the checkout has them; otherwise skipped silently.
func realHinglish() -> (Lexicon, NGramModel)? {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }   // file, IBoardEngineTests, Tests, IBoardEngine, Packages -> repo root
    let dir = url.appendingPathComponent("Data/hinglish")
    guard let lex = try? Lexicon(url: dir.appendingPathComponent("lexicon.iblex")),
          let lm = try? NGramModel(url: dir.appendingPathComponent("lm.iblm"), lexicon: lex) else { return nil }
    return (lex, lm)
}

@Suite struct RealHinglishDataTests {
    @Test func artifactsLoadAndKnowTheCommonForms() throws {
        guard let (lex, lm) = realHinglish() else { print("REAL-HINGLISH skipped: Data/hinglish not found"); return }
        print("REAL-HINGLISH loaded: \(lex.wordCount) words, \(lm.bigramCount) bigrams, \(lm.trigramCount) trigrams")
        #expect(lex.wordCount > 40_000)
        for w in ["hai", "nahi", "nhi", "nahin", "kya", "kyaa", "yaar", "bhai", "meeting", "kal"] {
            #expect(lex.lookup(w) != nil, "\(w)")
        }
        let nahi = try #require(lex.lookup("nahi")), nhi = try #require(lex.lookup("nhi")), hai = try #require(lex.lookup("hai"))
        let pata = try #require(lex.lookup("pata"))
        // "pata nahi" / "pata nhi" are likelier than a random word after "pata".
        let bg = lm.bigramProbability(nahi, after: pata)
        #expect(bg > lm.unigramProbability(nahi))
        #expect(lm.bigramProbability(nhi, after: pata) > lm.unigramProbability(nhi))
        #expect(lm.bigramProbability(hai, after: try #require(lex.lookup("kya"))) > lm.unigramProbability(hai))
    }

    @Test func dualDecodingWithTheRealHinglishData() throws {
        guard let (hi, hiLM) = realHinglish() else { return }
        let en = try Fixture.small.lexicon(), enLM = try Fixture.small.model(lexicon: en)
        let dec = TapDecoder(layout: testLayout, lexicon: en, model: enLM, secondary: SecondaryLanguage(lexicon: hi, model: hiLM))
        for w in ["nahi", "nhi", "kya", "yaar", "bhai", "accha", "bahut", "mujhe", "kyunki", "chahiye"] {
            let r = dec.decode(points: w.map(centre))
            #expect(r.candidates.first?.word == w && r.autocorrect == nil, "\(w) -> \(r.candidates.map(\.word))")
        }
    }
}
