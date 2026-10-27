import CoreGraphics
import Foundation
import IBoardLayout

/// 2-D Gaussian touch model of one key, in the key-centre-normalized frame of `KeyHit.normalized`
/// (units of the key's own width / height, so it survives resizing and layout changes). The personal model (F14)
/// will supply learned per-key values here.
public struct KeySpatialModel: Sendable, Equatable {
    public var meanX: Double
    public var meanY: Double
    public var sigmaX: Double
    public var sigmaY: Double

    public init(meanX: Double = 0, meanY: Double = 0, sigmaX: Double, sigmaY: Double) {
        self.meanX = meanX
        self.meanY = meanY
        self.sigmaX = sigmaX
        self.sigmaY = sigmaY
    }
}

public struct TapDecoderParameters: Sendable, Equatable {
    /// Touch spread of an average key, in key sizes (about 0.3 means 95% of taps land within 0.6 key widths).
    public var defaultSigma = KeySpatialModel(sigmaX: 0.30, sigmaY: 0.30)
    /// Per-key overrides (learned bias / spread).
    public var keyModels: [KeyIdentity: KeySpatialModel] = [:]
    /// Hypotheses kept after each touch.
    public var beamWidth = 24
    /// At most this many letter keys are considered per touch...
    public var maxKeysPerTouch = 4
    /// ...and only those within this many nats of the best key for that touch.
    public var keyWindow = 6.0
    /// Weight of the language-model log-probability against the spatial log-likelihood.
    public var lmWeight = 1.0
    /// Log-probability charged to a typed string that is not in the lexicon (the literal fallback).
    public var oovLogProbability = -14.0
    /// Flat penalty (nats) for suggesting a completion longer than what was typed.
    public var completionPenalty = 1.0
    /// Beams that get prefix completions, and completions taken per beam.
    public var completionSources = 3
    public var completionsPerSource = 6
    /// Length of the returned candidate list.
    public var maxCandidates = 8
    /// Edit-aware candidates (at most one edit per reading): adjacent transposition ("teh" -> "the"), a missing
    /// letter ("helo" -> "hello") and an extra tap ("helllo" -> "hello"). Each charges a flat penalty in nats.
    public var enableEdits = true
    public var transpositionPenalty = 3.0
    public var deletionPenalty = 8.0
    public var insertionPenalty = 8.0
    /// Hypotheses kept per layer that already used their edit (the zero-edit beam keeps `beamWidth`).
    public var editBeamWidth = 12

    public init() {}
}

public struct TapCandidate: Sendable, Equatable {
    public var word: String
    /// Lexicon id; nil for an out-of-vocabulary literal.
    public var wordID: Lexicon.WordID?
    /// Log of the unnormalised posterior: spatial log-likelihood + lmWeight * LM log-probability (- penalty).
    public var score: Double
    /// True when the word is longer than the typed letters (a prediction, never an autocorrect target).
    public var isCompletion: Bool
    /// True when this is the string exactly under the fingers (nearest key per touch).
    public var isLiteral: Bool
    /// Lexicon the word and `wordID` belong to (always `.primary` without a secondary language).
    public var side: LexiconSide = .primary
    /// Language log-prior (nats, before `lmWeight`) already included in `score`; 0 without a secondary language.
    public var languagePrior: Double = 0
}

public struct TapDecodeResult: Sendable, Equatable {
    /// Nearest letter key for every touch, concatenated. Always shown / kept verbatim by the caller on request.
    public var literal: String
    /// Best first.
    public var candidates: [TapCandidate]
    /// Best same-length word when it beats the literal; nil when the literal itself is the most likely reading.
    public var autocorrect: TapCandidate?
    /// Posterior probability (0...1) of `autocorrect` among all same-length readings including the literal;
    /// 0 when `autocorrect` is nil. The caller compares it with its own threshold.
    public var autocorrectConfidence: Double
    /// Posterior of the literal among the same-length readings.
    public var literalPosterior: Double
    /// True when an autocorrect to a primary-only word was withheld because the literal is a valid word of the
    /// secondary lexicon (M7-03).
    public var literalProtected: Bool = false
}

/// Tap decoder: per-key Gaussian spatial model times the language model, beam search over the touch sequence.
///
/// Deterministic (no clocks, no hashing order, explicit tie-breaks) and immutable after init, so it can be shared
/// across threads; each `decode` call keeps its own small working set. It decodes one word's letter taps;
/// the caller splits words at space / punctuation and supplies up to two previous word ids as context.
///
/// Code-switching (M7-02): with a `secondary` language the beam search runs over both lexicons; every candidate
/// carries its `side`, the score adds `lmWeight * priorWeight * log P(side | previous words)`, and the best score
/// wins when a word exists in both. Without a secondary language the behaviour is unchanged.
public struct TapDecoder: Sendable {
    public let lexicon: Lexicon
    public let model: NGramModel?
    public let parameters: TapDecoderParameters
    public let secondary: SecondaryLanguage?
    public let codeSwitch: CodeSwitchParameters

    private struct LetterKey: Sendable {
        var scalar: UInt32
        var centerX: Double
        var centerY: Double
        var width: Double
        var height: Double
        var spatial: KeySpatialModel
        var logNorm: Double   // -log(sigmaX * sigmaY)
    }

    private let letters: [LetterKey]
    /// Distinct letter scalars, ascending (labels tried for a missing letter).
    private let labels: [UInt32]

    public init(layout: KeyboardLayout, lexicon: Lexicon, model: NGramModel? = nil,
                parameters: TapDecoderParameters = TapDecoderParameters(),
                secondary: SecondaryLanguage? = nil, codeSwitch: CodeSwitchParameters = CodeSwitchParameters()) {
        var l: [LetterKey] = []
        for key in layout.keys {
            guard case .letter(let s) = key.identity, s.unicodeScalars.count == 1,
                  key.frame.width > 0, key.frame.height > 0 else { continue }
            let sm = parameters.keyModels[key.identity] ?? parameters.defaultSigma
            l.append(LetterKey(
                scalar: s.unicodeScalars.first!.value,
                centerX: Double(key.frame.midX), centerY: Double(key.frame.midY),
                width: Double(key.frame.width), height: Double(key.frame.height),
                spatial: sm, logNorm: -log(sm.sigmaX * sm.sigmaY)))
        }
        letters = l
        labels = Array(Set(l.map(\.scalar))).sorted()
        self.lexicon = lexicon
        self.model = model
        self.parameters = parameters
        self.secondary = secondary
        self.codeSwitch = codeSwitch
    }

    /// Convenience for the keyboard: the touches as `KeyHit`s resolved by the layout (the offsets are relative to
    /// the key each touch landed on, so the touch point is reconstructed from it).
    public func decode(hits: [KeyHit], layout: KeyboardLayout, context: LMContext = .none,
                       secondaryContext: SecondaryContext = .neutral) -> TapDecodeResult {
        let points = hits.map { h -> CGPoint in
            let k = layout.keys[h.keyIndex]
            return CGPoint(x: k.frame.midX + h.normalized.x * k.frame.width, y: k.frame.midY + h.normalized.y * k.frame.height)
        }
        return decode(points: points, context: context, secondaryContext: secondaryContext)
    }

    private struct Hypothesis {
        var cursor: TrieCursor
        var spatial: Double
        var priority: Double
        /// 0 or 1 edits used so far, and the nats charged for it.
        var edits: UInt8 = 0
        var penalty: Double = 0
    }

    /// Orders by priority, then trie node, then edits; drops repeats of (node, edits); keeps the best `beamWidth`
    /// zero-edit and `editBeamWidth` one-edit hypotheses. With no edits this equals the plain beam prune.
    private func prune(_ hs: inout [Hypothesis]) {
        hs.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.cursor.node != $1.cursor.node { return $0.cursor.node < $1.cursor.node }
            return $0.edits < $1.edits
        }
        var kept: [Hypothesis] = []
        kept.reserveCapacity(min(hs.count, parameters.beamWidth + parameters.editBeamWidth))
        var zero = 0, one = 0
        for h in hs {
            if h.edits == 0 {
                if zero >= parameters.beamWidth { continue }
                zero += 1
            } else {
                if one >= parameters.editBeamWidth { continue }
                if kept.contains(where: { $0.edits == 1 && $0.cursor == h.cursor }) { continue }
                one += 1
            }
            kept.append(h)
        }
        hs = kept
    }

    /// One language: the lexicon, its LM, the n-gram context in its ids and its language log-prior.
    private struct Side {
        var side: LexiconSide
        var lexicon: Lexicon
        var model: NGramModel?
        var context: LMContext
        var prior: Double

        func lmLog(_ id: Lexicon.WordID) -> Double {
            if let model { return model.logProbability(id, context: context) }
            return lexicon.logProbability(of: id)
        }
    }

    /// Touch evidence shared by both sides.
    private struct Touches {
        var n: Int
        var keyCap: Int
        var candKey: [Int]
        var candLL: [Double]
        var candCount: [Int]
    }

    /// Decode touch points (container coordinates of the layout this decoder was built for).
    public func decode(points: [CGPoint], context: LMContext = .none,
                       secondaryContext: SecondaryContext = .neutral) -> TapDecodeResult {
        let n = points.count
        let p = parameters
        guard n > 0, !letters.isEmpty else {
            return TapDecodeResult(literal: "", candidates: [], autocorrect: nil, autocorrectConfidence: 0, literalPosterior: 0)
        }
        let keyCap = max(1, p.maxKeysPerTouch)

        // 1. Spatial log-likelihood of every touch under every letter key; keep the best few per touch.
        var candKey = [Int](repeating: 0, count: n * keyCap)
        var candLL = [Double](repeating: 0, count: n * keyCap)
        var candCount = [Int](repeating: 0, count: n)
        var lls = [Double](repeating: 0, count: letters.count)
        var literalScalars = String.UnicodeScalarView()
        var literalSpatial = 0.0
        for t in 0..<n {
            let pt = points[t]
            for (i, k) in letters.enumerated() {
                let dx = ((Double(pt.x) - k.centerX) / k.width - k.spatial.meanX) / k.spatial.sigmaX
                let dy = ((Double(pt.y) - k.centerY) / k.height - k.spatial.meanY) / k.spatial.sigmaY
                lls[i] = -0.5 * (dx * dx + dy * dy) + k.logNorm
            }
            var best = -Double.infinity
            var taken = 0
            while taken < keyCap {
                var bi = -1
                var bv = -Double.infinity
                for i in 0..<lls.count where lls[i] > bv { bv = lls[i]; bi = i }   // ties: lowest index
                if bi < 0 { break }
                if taken == 0 { best = bv } else if bv < best - p.keyWindow { break }
                candKey[t * keyCap + taken] = bi
                candLL[t * keyCap + taken] = bv
                taken += 1
                lls[bi] = -Double.infinity
            }
            candCount[t] = taken
            let top = letters[candKey[t * keyCap]]
            literalScalars.append(Unicode.Scalar(top.scalar) ?? "?")
            literalSpatial += candLL[t * keyCap]
        }
        let literal = String(literalScalars)
        let touches = Touches(n: n, keyCap: keyCap, candKey: candKey, candLL: candLL, candCount: candCount)

        var sides = [Side(side: .primary, lexicon: lexicon, model: model, context: context, prior: 0)]
        if let secondary {
            sides[0].prior = codeSwitch.priorWeight * secondaryContext.logPrior(.primary)
            sides.append(Side(side: .secondary, lexicon: secondary.lexicon, model: secondary.model,
                              context: secondaryContext.lm, prior: codeSwitch.priorWeight * secondaryContext.logPrior(.secondary)))
        }
        let dual = sides.count > 1

        // 2. Same-length readings of every side, merged by word text (best score wins; primary wins ties).
        var full: [TapCandidate] = []
        var fullIndex: [String: Int] = [:]
        func upsert(_ c: TapCandidate) {
            if let i = fullIndex[c.word] {
                if c.score > full[i].score { full[i] = c }
                return
            }
            fullIndex[c.word] = full.count
            full.append(c)
        }
        var beams: [[Hypothesis]] = []
        for s in sides {
            let finalBeam = beamSearch(s.lexicon, touches)
            // Completions come from the zero-edit beam only.
            beams.append(finalBeam.filter { $0.edits == 0 })
            for h in finalBeam {
                guard let w = s.lexicon.wordID(at: h.cursor) else { continue }
                let score = h.spatial + p.lmWeight * (s.lmLog(w) + s.prior) - h.penalty
                upsert(TapCandidate(word: s.lexicon.word(of: w), wordID: w, score: score, isCompletion: false,
                                    isLiteral: false, side: s.side, languagePrior: s.prior))
            }
        }

        // 3. The literal: from the beam when it is there, else looked up directly in each lexicon, else out of vocabulary.
        var literalInSecondary = false
        var literalKnown = false
        for s in sides {
            if let lc = s.lexicon.cursor(for: literal), let lw = s.lexicon.wordID(at: lc) {
                literalKnown = true
                if s.side == .secondary { literalInSecondary = true }
                upsert(TapCandidate(word: literal, wordID: lw, score: literalSpatial + p.lmWeight * (s.lmLog(lw) + s.prior),
                                    isCompletion: false, isLiteral: false, side: s.side, languagePrior: s.prior))
            }
        }
        if !literalKnown {
            let prior = sides.map(\.prior).max() ?? 0   // not in any lexicon: charge no language
            upsert(TapCandidate(word: literal, wordID: nil, score: literalSpatial + p.lmWeight * (p.oovLogProbability + prior),
                                isCompletion: false, isLiteral: false, side: .primary, languagePrior: prior))
        }
        let literalIndex = fullIndex[literal]
        if let i = literalIndex { full[i].isLiteral = true }

        // 4. Posterior over the same-length readings -> autocorrect decision and confidence.
        var top = 0
        for i in 1..<full.count where full[i].score > full[top].score
            || (full[i].score == full[top].score && Self.before(full[i], full[top])) { top = i }
        let maxScore = full[top].score
        var z = 0.0
        for c in full { z += exp(c.score - maxScore) }
        let literalPosterior = literalIndex.map { exp(full[$0].score - maxScore) / z } ?? 0
        var autocorrect: TapCandidate?
        var confidence = 0.0
        var protected = false
        if !full[top].isLiteral {
            if dual, codeSwitch.protectSecondaryWords, literalInSecondary, full[top].side == .primary,
               let secondary, secondary.lexicon.lookup(full[top].word) == nil {
                protected = true   // M7-03: a valid Hinglish word is never auto-corrected into English
            } else {
                autocorrect = full[top]
                confidence = 1 / z
            }
        }

        // 5. Completions of the most promising prefixes (predictions, never autocorrect targets).
        var all = full
        var scratch = CompletionScratch()
        var ids: [Lexicon.WordID] = []
        var have = Set<String>(dual ? all.map(\.word) : [])
        for (s, beam) in zip(sides, beams) {
            for h in beam.prefix(p.completionSources) where s.lexicon.hasChildren(h.cursor) {
                s.lexicon.completions(of: h.cursor, limit: p.completionsPerSource + 1, scratch: &scratch, into: &ids)
                let own = s.lexicon.wordID(at: h.cursor)
                for w in ids where w != own {
                    let word = s.lexicon.word(of: w)
                    if dual, !have.insert(word).inserted { continue }
                    all.append(TapCandidate(word: word, wordID: w,
                                            score: h.spatial + p.lmWeight * (s.lmLog(w) + s.prior) - p.completionPenalty,
                                            isCompletion: true, isLiteral: false, side: s.side, languagePrior: s.prior))
                }
            }
        }
        all.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.isCompletion != $1.isCompletion { return !$0.isCompletion }
            return Self.before($0, $1)
        }
        if all.count > p.maxCandidates {
            // The literal always stays in the list (the strip offers it verbatim, and its wordID tells the caller
            // whether it is a valid word), even when its score would rank it below the cut.
            let literalCandidate = all.first { $0.isLiteral }
            all.removeLast(all.count - p.maxCandidates)
            if let literalCandidate, !all.contains(where: { $0.isLiteral }) { all[all.count - 1] = literalCandidate }
        }
        return TapDecodeResult(literal: literal, candidates: all, autocorrect: autocorrect,
                               autocorrectConfidence: confidence, literalPosterior: literalPosterior,
                               literalProtected: protected)
    }

    /// Deterministic tie-break: smaller word id first, then primary before secondary.
    private static func before(_ a: TapCandidate, _ b: TapCandidate) -> Bool {
        let x = a.wordID ?? .max, y = b.wordID ?? .max
        if x != y { return x < y }
        return a.side < b.side
    }

    /// Beam search through one lexicon's trie, layered by number of touches consumed. Priority = spatial +
    /// optimistic LM (best word below the node) - edit penalty. Zero-edit hypotheses behave exactly as the plain
    /// beam; reading hypotheses with one edit live next to them (transposition jumps two touches, an extra tap
    /// jumps one without a letter, a missing letter adds a letter without a touch).
    private func beamSearch(_ lexicon: Lexicon, _ t: Touches) -> [Hypothesis] {
        let p = parameters
        let n = t.n, keyCap = t.keyCap
        let editsOn = p.enableEdits && n >= 2
        var layers = [[Hypothesis]](repeating: [], count: n + 1)
        layers[0] = [Hypothesis(cursor: lexicon.root, spatial: 0, priority: 0)]
        var finalBeam: [Hypothesis] = []
        for k in 0...n {
            var layer = layers[k]
            layers[k] = []
            if editsOn, k > 0, k < n {
                let base = layer.count
                for i in 0..<base where layer[i].edits == 0 {
                    let h = layer[i]
                    for label in labels {
                        guard let c = lexicon.child(of: h.cursor, label: label) else { continue }
                        layer.append(Hypothesis(cursor: c, spatial: h.spatial,
                                                priority: h.spatial + p.lmWeight * lexicon.bestLogProbability(under: c) - p.deletionPenalty,
                                                edits: 1, penalty: p.deletionPenalty))
                    }
                }
            }
            prune(&layer)
            if k == n { finalBeam = layer; break }
            for h in layer {
                for j in 0..<t.candCount[k] {
                    let label = letters[t.candKey[k * keyCap + j]].scalar
                    guard let c = lexicon.child(of: h.cursor, label: label) else { continue }
                    let s = h.spatial + t.candLL[k * keyCap + j]
                    layers[k + 1].append(Hypothesis(cursor: c, spatial: s,
                                                    priority: s + p.lmWeight * lexicon.bestLogProbability(under: c) - h.penalty,
                                                    edits: h.edits, penalty: h.penalty))
                }
                guard editsOn, h.edits == 0 else { continue }
                // Extra tap: this touch produced no letter.
                layers[k + 1].append(Hypothesis(cursor: h.cursor, spatial: h.spatial,
                                                priority: h.priority - p.insertionPenalty,
                                                edits: 1, penalty: p.insertionPenalty))
                // Transposition: touches k and k+1 were typed in the wrong order.
                if k + 1 < n {
                    for jx in 0..<t.candCount[k + 1] {
                        let x = letters[t.candKey[(k + 1) * keyCap + jx]].scalar
                        guard let cx = lexicon.child(of: h.cursor, label: x) else { continue }
                        for jy in 0..<t.candCount[k] {
                            let y = letters[t.candKey[k * keyCap + jy]].scalar
                            guard y != x, let cy = lexicon.child(of: cx, label: y) else { continue }
                            let s = h.spatial + t.candLL[(k + 1) * keyCap + jx] + t.candLL[k * keyCap + jy]
                            layers[k + 2].append(Hypothesis(
                                cursor: cy, spatial: s,
                                priority: s + p.lmWeight * lexicon.bestLogProbability(under: cy) - p.transpositionPenalty,
                                edits: 1, penalty: p.transpositionPenalty))
                        }
                    }
                }
            }
        }
        return finalBeam
    }
}
