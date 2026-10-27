import CoreGraphics
import Foundation

/// One touch sample of a swipe, container coordinates of the layout the decoder was built for.
public struct SwipePoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    /// Seconds on any monotonic clock (only differences are used). Pass 0 for all samples when unknown;
    /// dwell detection is then skipped and corner detection alone is used.
    public var t: Double

    public init(x: Double, y: Double, t: Double = 0) {
        self.x = x
        self.y = y
        self.t = t
    }

    public init(_ p: CGPoint, t: Double = 0) {
        self.init(x: Double(p.x), y: Double(p.y), t: t)
    }
}

public struct SwipeParameters: Sendable, Equatable {
    // Resampling
    /// Points of the equidistant resampled gesture and templates (SHARK2 uses 100; 48 is enough for words).
    public var resampleCount = 48
    /// Paths shorter than this many key widths are not swipes (the decoder returns no candidates).
    public var minPathKeyWidths = 1.0

    // Candidate pruning
    /// A letter key is allowed in a word only if its centre is within this many key sizes of the path.
    public var corridorRadius = 1.3
    /// The first / last letter of a word must be within this many key sizes of the path start / end.
    public var endRadius = 1.3
    /// Hard cap on trie nodes visited per decode (keeps latency bounded; reported in the result).
    public var maxNodeVisits = 60_000
    /// Words longer than this are never candidates.
    public var maxWordLength = 20

    // Spatial model (log-likelihood = -0.5 * (shape^2 + location^2 + anchors))
    /// Scale of the shape channel (normalized units, shape distance of 1 sigma).
    public var shapeSigma = 0.09
    /// Scale of the location channel in key widths (after the free `locationTolerance`).
    public var locationSigma = 0.30
    /// Distance (key widths) inside which the location channel charges nothing.
    public var locationTolerance = 0.35
    /// Scale (key sizes) of the dwell / corner anchor penalty, and the cap on one anchor's distance.
    public var anchorSigma = 0.6
    public var anchorCap = 1.5
    /// Weight of the anchor term relative to shape and location.
    public var anchorWeight = 0.5

    /// Extra penalty on the first / last path point versus the word's first / last key centre: weight (0 = off),
    /// free radius and scale in key widths.
    public var endpointWeight = 2.0
    public var endpointTolerance = 0.5
    public var endpointSigma = 0.5

    // Anchors
    /// A corner is a turn of at least this many degrees within a short window of the smoothed path.
    public var cornerDegrees = 55.0
    /// Speed (key widths / s) below which samples count as dwelling, and the minimum dwell time (s).
    public var dwellSpeed = 2.0
    public var dwellMinSeconds = 0.06

    // Scoring
    /// Log-score charged to words containing an apostrophe: the apostrophe is invisible in the path, so a
    /// contraction explains the swipe with a free extra letter; the charge offsets that (want vs wasn't).
    public var contractionPenalty = 0.5
    /// Weight of the language-model log-probability against the spatial log-likelihood.
    public var lmWeight = 0.4
    /// Share of the unigram probability mixed into the contextual (bigram / trigram) probability before it is scored,
    /// so an unseen continuation is not charged the full backoff penalty (0 = off). DATA2: 0.3, tuned on the even Hinglish eval sentences with `lmWeight`.
    public var lmUnigramMix = 0.3
    /// Log-probability charged to a personal word that is not in the base lexicon.
    public var oovLogProbability = -16.0
    /// Personal-model words considered per allowed first letter that are not in the base lexicon (0 disables).
    public var personalOOVPerLetter = 24
    /// Number of ranked candidates returned.
    public var maxCandidates = 6

    public init() {}
}

public struct SwipeCandidate: Sendable, Equatable {
    public var word: String
    /// Lexicon id; nil for a word known only to the personal model.
    public var wordID: Lexicon.WordID?
    /// Total log score (unnormalised log posterior): spatial + lmWeight * language-model log-probability.
    public var score: Double
    public var spatial: Double
    /// Language-model log-probability after mixing with the personal model.
    public var language: Double
    /// True when the personal model contributed to `language`.
    public var usedPersonal: Bool
    /// Lexicon the word and `wordID` belong to (always `.primary` without a secondary language).
    public var side: LexiconSide = .primary
}

public struct SwipeDecodeResult: Sendable, Equatable {
    /// Best first.
    public var candidates: [SwipeCandidate]
    /// Posterior probability (0...1) of the top candidate among all scored candidates; 0 when there are none.
    public var confidence: Double
    /// Posterior of the top candidate minus that of the runner-up.
    public var margin: Double
    /// Candidates that reached template scoring, trie nodes visited, and whether `maxNodeVisits` cut the search.
    public var scoredCount: Int
    public var nodesVisited: Int
    public var truncated: Bool
    /// Dwell and corner anchors found (excluding the two ends).
    public var anchorCount: Int
    /// False when the path was too short to be a swipe (the caller should treat the touch as a tap).
    public var isSwipe: Bool

    static let notASwipe = SwipeDecodeResult(candidates: [], confidence: 0, margin: 0, scoredCount: 0,
                                             nodesVisited: 0, truncated: false, anchorCount: 0, isSwipe: false)
}
