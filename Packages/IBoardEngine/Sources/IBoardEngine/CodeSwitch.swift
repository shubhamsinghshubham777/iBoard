import Foundation

/// Which of the two lexicons a candidate came from. Word ids are only meaningful together with their side.
public enum LexiconSide: UInt8, Sendable, Comparable {
    /// The main language (English).
    case primary = 0
    /// The code-switched language (Hinglish).
    case secondary = 1

    public static func < (a: LexiconSide, b: LexiconSide) -> Bool { a.rawValue < b.rawValue }
}

/// Second lexicon (and optional LM) searched together with the primary one (M7-02, docs/HINGLISH.md).
public struct SecondaryLanguage: Sendable {
    public let lexicon: Lexicon
    public let model: NGramModel?

    public init(lexicon: Lexicon, model: NGramModel? = nil) {
        self.lexicon = lexicon
        self.model = model
    }

    @inline(__always)
    func logProbability(_ id: Lexicon.WordID, _ ctx: LMContext) -> Double {
        if let model { return model.logProbability(id, context: ctx) }
        return lexicon.logProbability(of: id)
    }
}

/// Tuning of the code-switch scoring. With no secondary language none of this has any effect.
public struct CodeSwitchParameters: Sendable, Equatable {
    /// P(secondary language) before any context, in (0, 1). 0.5 = no preference.
    public var secondaryPrior = 0.5
    /// Log-odds (nats) one unambiguous previous word adds toward its language (before decay).
    public var tokenEvidence = 1.1
    /// Each earlier word counts this much less than the one after it.
    public var decay = 0.65
    /// Previous words examined.
    public var contextTokens = 4
    /// Cap on the absolute context log-odds, so one language never completely shuts the other out.
    public var maxLogOdds = 3.0
    /// Scale of the personal-model language bias (0 disables it) and its cap in nats.
    public var personalWeight = 1.0
    public var maxPersonalBias = 1.5
    /// Weight of the language log-prior in a candidate's score (multiplied with the decoder's `lmWeight`).
    public var priorWeight = 1.0
    /// Never auto-correct a typed word that is valid in the secondary lexicon into a word that exists only in the
    /// primary lexicon (M7-03). The suggestion strip still offers the English word.
    public var protectSecondaryWords = true

    public init() {}
}

/// What the decoders need to score the secondary side for one request: the n-gram context in the secondary
/// lexicon's ids and the language log-odds from the previous words.
public struct SecondaryContext: Sendable, Equatable {
    public var lm: LMContext
    /// log(P(secondary) / P(primary)) given the previous words and the personal bias.
    public var logOdds: Double

    public init(lm: LMContext = .none, logOdds: Double = 0) {
        self.lm = lm
        self.logOdds = logOdds
    }

    public static let neutral = SecondaryContext()

    /// log P(side | context), a log-sigmoid of the odds.
    public func logPrior(_ side: LexiconSide) -> Double {
        let x = side == .secondary ? logOdds : -logOdds
        return x >= 0 ? -log1p(exp(-x)) : x - log1p(exp(x))
    }
}

public enum CodeSwitch {
    /// Language context from the previous words (oldest first; only the last `contextTokens` count). A word that is
    /// in only one lexicon is evidence for that language; a word in both, or in neither, is neutral.
    /// `personalBias` is the personal model's EN vs Hinglish lean (see `personalBias`), in nats.
    public static func context(previousWords: [String], primary: Lexicon, secondary: SecondaryLanguage,
                               parameters p: CodeSwitchParameters, personalBias: Double = 0) -> (primary: LMContext, secondary: SecondaryContext) {
        let last = previousWords.suffix(2)
        let pIDs = last.map { primary.lookup($0) }
        let sIDs = last.map { secondary.lexicon.lookup($0) }
        func lm(_ ids: [Lexicon.WordID?]) -> LMContext {
            switch ids.count {
            case 2: return LMContext(older: ids[0], recent: ids[1])
            case 1: return LMContext(recent: ids[0])
            default: return .none
            }
        }
        let prior = min(max(p.secondaryPrior, 1e-6), 1 - 1e-6)
        var odds = log(prior / (1 - prior)) + personalBias
        var weight = p.tokenEvidence
        for w in previousWords.suffix(max(0, p.contextTokens)).reversed() {
            let inP = primary.lookup(w) != nil
            let inS = secondary.lexicon.lookup(w) != nil
            if inS && !inP { odds += weight } else if inP && !inS { odds -= weight }
            weight *= p.decay
        }
        odds = min(max(odds, -p.maxLogOdds), p.maxLogOdds)
        return (lm(pIDs), SecondaryContext(lm: lm(sIDs), logOdds: odds))
    }

    /// The personal model's lean between the two languages: the usage-weighted share of its most used words that
    /// exist only in the secondary lexicon versus only in the primary one, as shrunk log-odds in nats (positive =
    /// leans Hinglish). Small personal vocabularies give a bias near 0. Reads the personal model only (nothing typed
    /// is stored); call once per personal snapshot, not per keystroke.
    public static func personalBias(from scorer: any PersonalScoreProvider, primary: Lexicon,
                                    secondary: SecondaryLanguage, parameters p: CodeSwitchParameters) -> Double {
        guard p.personalWeight > 0 else { return 0 }
        var s = 0.0, e = 0.0
        for c in scorer.completions(prefix: "", limit: 400) {
            let w = c.word.lowercased()
            let inP = primary.lookup(w) != nil
            let inS = secondary.lexicon.lookup(w) != nil
            if inS && !inP { s += c.weight } else if inP && !inS { e += c.weight }
        }
        // Add-one-style shrinkage toward 50/50 with a pseudo-mass of 20 (about a dozen learned words).
        let share = (s + 10) / (s + e + 20)
        let bias = log(share / (1 - share)) * p.personalWeight
        return min(max(bias, -p.maxPersonalBias), p.maxPersonalBias)
    }

    /// M7-03: true when correcting `literal` to `target` would turn a valid secondary-lexicon word into a word that
    /// exists only in the primary lexicon.
    public static func isProtected(literal: String, target: String, secondary: SecondaryLanguage) -> Bool {
        secondary.lexicon.lookup(literal) != nil && secondary.lexicon.lookup(target) == nil
    }
}
