import Foundation

/// What the personal model says about one candidate word in context.
public struct PersonalScore: Sendable, Equatable {
    /// Estimated P(word | context) from personal counts (interpolated unigram/bigram/trigram), in (0, 1].
    public var probability: Double
    /// How much the engine should trust the personal model overall, in [0, maxWeight]. Grows with personal data mass.
    public var weight: Double
}

public struct PersonalCompletion: Sendable, Equatable {
    public var word: String      // display form (casing preserved where known)
    public var weight: Double    // effective unigram weight
}

/// Seam for the EngineActor: it asks this for per-candidate personal evidence and combines it with the base LM via
/// `PersonalInterpolation.mix`. Synchronous and allocation-light so it can be called from decoder inner loops.
public protocol PersonalScoreProvider: Sendable {
    /// `context` is the preceding words, oldest first (only the last two are used). `nil` when the personal model has
    /// no opinion (unknown word, empty model).
    func score(word: String, context: [String]) -> PersonalScore?
    /// Personal words starting with `prefix`, best first.
    func completions(prefix: String, limit: Int) -> [PersonalCompletion]
    func isForgotten(_ word: String) -> Bool
    func isNeverCorrect(_ word: String) -> Bool
}

public enum PersonalInterpolation {
    /// Personal trust never exceeds this share of the mixture.
    public static let maxWeight = 0.4
    /// Mass (sum of effective unigram weights) at which trust reaches half of `maxWeight`.
    public static let halfTrustMass = 300.0

    public static func trust(forMass mass: Double) -> Double {
        guard mass > 0 else { return 0 }
        return maxWeight * mass / (mass + halfTrustMass)
    }

    /// Log of `(1 - w) * exp(baseLogProb) + w * personal.probability`. Returns `baseLogProb` when personal is nil.
    /// The base log-probability should already include the engine's unknown-word floor for words the base LM lacks.
    public static func mix(baseLogProb: Double, personal: PersonalScore?) -> Double {
        guard let p = personal, p.weight > 0, p.probability > 0 else { return baseLogProb }
        let a = log(1 - p.weight) + baseLogProb
        let b = log(p.weight) + log(p.probability)
        let m = max(a, b)
        return m + log(exp(a - m) + exp(b - m))
    }
}

/// Immutable scoring snapshot of the personal model. Value type, `Sendable`.
public struct PersonalScorer: PersonalScoreProvider {
    private let state: PersonalModelState
    private let now: Double
    private let mass: Double

    init(state: PersonalModelState, asOf now: Double) {
        self.state = state
        self.now = now
        self.mass = state.totalUnigramMass(at: now)
    }

    public var isEmpty: Bool { state.unigrams.isEmpty }

    public func score(word: String, context: [String]) -> PersonalScore? {
        let w = PersonalStore.normalize(word)
        guard mass > 0, !state.forgotten.keys.contains(w),
              let u = state.unigrams[w] else { return nil }
        let cw = state.effective(u, at: now)
        guard cw > 0 else { return nil }
        var p = cw / mass
        let ctx = context.suffix(2).map(PersonalStore.normalize)
        if let a = ctx.last, let ua = state.unigrams[a] {
            let ca = state.effective(ua, at: now)
            let cab = state.effectiveWeight(.bigram, PersonalModelState.key([a, w]), at: now)
            if ca > 0, cab > 0 {
                let pBi = min(1, cab / ca)
                let lamBi = ca / (ca + 1)
                var pHigher = pBi
                if ctx.count == 2 {
                    let b = ctx[0]
                    let cb = state.effectiveWeight(.bigram, PersonalModelState.key([b, a]), at: now)
                    let cbaw = state.effectiveWeight(.trigram, PersonalModelState.key([b, a, w]), at: now)
                    if cb > 0, cbaw > 0 {
                        let lamTri = cb / (cb + 1)
                        pHigher = lamTri * min(1, cbaw / cb) + (1 - lamTri) * pBi
                    }
                }
                p = lamBi * pHigher + (1 - lamBi) * p
            }
        }
        return PersonalScore(probability: max(p, 1e-9), weight: PersonalInterpolation.trust(forMass: mass))
    }

    public func completions(prefix: String, limit: Int) -> [PersonalCompletion] {
        let p = PersonalStore.normalize(prefix)
        guard limit > 0 else { return [] }
        var out: [PersonalCompletion] = []
        for (k, e) in state.unigrams where k.hasPrefix(p) && state.forgotten[k] == nil {
            out.append(PersonalCompletion(word: state.surfaces[k] ?? k, weight: state.effective(e, at: now)))
        }
        out.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.word < $1.word }
        return Array(out.prefix(limit))
    }

    public func isForgotten(_ word: String) -> Bool { state.forgotten[PersonalStore.normalize(word)] != nil }
    public func isNeverCorrect(_ word: String) -> Bool { state.neverCorrect.contains(PersonalStore.normalize(word)) }
}
