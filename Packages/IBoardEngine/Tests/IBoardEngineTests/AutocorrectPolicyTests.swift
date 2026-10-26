import Testing
import IBoardEngine

@Suite struct AutocorrectPolicyTests {
    let traits = AutocorrectTraits()
    let settings = AutocorrectSettings()

    func proposal(_ w: String = "the", _ c: Double = 0.99, literalIsWord: Bool = false) -> AutocorrectProposal {
        AutocorrectProposal(word: w, confidence: c, literalIsWord: literalIsWord)
    }

    @Test func highConfidenceCorrects() {
        let d = AutocorrectPolicy.decide(literal: "teh", proposal: proposal(), traits: traits, state: AutocorrectState())
        #expect(d == .correct(to: "the", confidence: 0.99))
    }

    @Test func lowConfidenceIsKept() {
        let d = AutocorrectPolicy.decide(literal: "teh", proposal: proposal("the", 0.9), traits: traits, state: AutocorrectState())
        #expect(d == .keepLiteral(.lowConfidence))
    }

    @Test func aggressivenessMovesTheThreshold() {
        var s = settings
        s.aggressiveness = .balanced
        #expect(AutocorrectPolicy.decide(literal: "teh", proposal: proposal("the", 0.92), traits: traits, settings: s, state: AutocorrectState())
                == .correct(to: "the", confidence: 0.92))
        s.aggressiveness = .conservative
        #expect(AutocorrectPolicy.decide(literal: "teh", proposal: proposal("the", 0.92), traits: traits, settings: s, state: AutocorrectState())
                == .keepLiteral(.lowConfidence))
    }

    @Test func knownWordLiteralNeedsExtraConfidence() {
        let st = AutocorrectState()
        #expect(AutocorrectPolicy.decide(literal: "form", proposal: proposal("from", 0.98, literalIsWord: true), traits: traits, state: st)
                == .keepLiteral(.lowConfidence))
        #expect(AutocorrectPolicy.decide(literal: "form", proposal: proposal("from", 0.999, literalIsWord: true), traits: traits, state: st)
                == .correct(to: "from", confidence: 0.999))
    }

    @Test func autocorrectionNoMeansSuggestionsOnly() {
        for t in [AutocorrectTraits(autocorrection: .no), AutocorrectTraits(spellChecking: .no)] {
            #expect(AutocorrectPolicy.decide(literal: "teh", proposal: proposal("the", 1), traits: t, state: AutocorrectState())
                    == .keepLiteral(.disabledByTraits))
        }
        // .yes and .default both allow it
        #expect(AutocorrectPolicy.decide(literal: "teh", proposal: proposal(), traits: AutocorrectTraits(autocorrection: .yes), state: AutocorrectState())
                == .correct(to: "the", confidence: 0.99))
    }

    @Test func noProposalTooShortAndNonLetters() {
        let st = AutocorrectState()
        #expect(AutocorrectPolicy.decide(literal: "teh", proposal: nil, traits: traits, state: st) == .keepLiteral(.noProposal))
        #expect(AutocorrectPolicy.decide(literal: "t", proposal: proposal(), traits: traits, state: st) == .keepLiteral(.tooShort))
        #expect(AutocorrectPolicy.decide(literal: "te1", proposal: proposal(), traits: traits, state: st) == .keepLiteral(.nonLetters))
    }

    @Test func backspaceRightAfterCorrectionRestoresOriginal() {
        var st = AutocorrectState()
        st.recordApplied(original: "teh", corrected: "the", trailing: " ", at: 100)
        let edit = st.backspace(at: 101, settings: settings)
        #expect(edit == TextEdit(deleteBackward: 4, insert: "teh"))
        #expect(st.lastCorrection == nil)
        #expect(st.backspace(at: 102) == nil, "a second backspace is an ordinary delete")
        #expect(st.restoreCounts["teh"] == 1)
        #expect(st.neverCorrect.isEmpty)
    }

    @Test func restoreAfterWindowOrAfterOtherInputDoesNothing() {
        var st = AutocorrectState()
        st.recordApplied(original: "teh", corrected: "the", trailing: " ", at: 0)
        #expect(st.backspace(at: settings.restoreWindow + 1, settings: settings) == nil)
        #expect(st.restoreCounts.isEmpty)

        st.recordApplied(original: "teh", corrected: "the", trailing: " ", at: 0)
        st.noteOtherInput()
        #expect(st.backspace(at: 1, settings: settings) == nil)
    }

    @Test func wordRestoredTwiceGoesOnNeverCorrectList() {
        var st = AutocorrectState()
        for i in 0..<2 {
            #expect(AutocorrectPolicy.decide(literal: "Teh", proposal: proposal(), traits: traits, state: st) == .correct(to: "the", confidence: 0.99), "round \(i)")
            st.recordApplied(original: "Teh", corrected: "The", trailing: ".", at: Double(i))
            #expect(st.backspace(at: Double(i) + 0.5) != nil)
        }
        #expect(st.neverCorrect == ["teh"])
        #expect(AutocorrectPolicy.decide(literal: "teh", proposal: proposal("the", 1), traits: traits, state: st) == .keepLiteral(.neverCorrectList))
        st.allowAgain("TEH")
        #expect(AutocorrectPolicy.decide(literal: "teh", proposal: proposal("the", 1), traits: traits, state: st) != .keepLiteral(.neverCorrectList))
    }

    @Test func choosingTheLiteralSlotCountsAsRestore() {
        var st = AutocorrectState()
        st.userChoseLiteral("zorp")
        #expect(st.neverCorrect.isEmpty)
        st.userChoseLiteral("zorp")
        #expect(st.neverCorrect == ["zorp"])
    }

    @Test func restoreLengthCountsGraphemes() {
        var st = AutocorrectState()
        st.recordApplied(original: "cafe", corrected: "cafe\u{301}", trailing: " 😀", at: 0)
        // "café" is 4 graphemes (combining accent), plus space and emoji
        #expect(st.backspace(at: 1)?.deleteBackward == 4 + 2)
    }

    @Test func seededNeverCorrectList() {
        let st = AutocorrectState(neverCorrect: ["kubectl"])
        #expect(AutocorrectPolicy.decide(literal: "kubectl", proposal: proposal(), traits: traits, state: st) == .keepLiteral(.neverCorrectList))
    }
}
