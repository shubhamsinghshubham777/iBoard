import CoreGraphics
import Foundation
import IBoardLayout

/// Swipe (gesture) typing decoder, SHARK2-style template matching.
///
/// 1. The path is converted to the key frame (one unit is about one key) and resampled to equidistant points.
/// 2. The lexicon trie is walked, pruned to words whose first / last letter key is near the path start / end and
///    whose every letter key lies in a corridor around the path *in path order*.
/// 3. Each surviving word gets a template: the polyline through its letter-key centres of the CURRENT layout
///    (so split, Duo and resized layouts work unchanged), resampled the same way. Two channels are compared:
///    shape (both normalized for position and scale) and location (absolute distance beyond a tolerance).
///    Dwell and corner points of the gesture add an anchor penalty when no letter of the word is near them.
/// 4. spatial log-likelihood + `lmWeight` * language log-probability (n-gram, mixed with the personal model for the
///    shortlist) ranks the candidates; the posterior of the top one is the confidence.
///
/// Deterministic (no clocks, randomness or hashing order; ties broken by word id), immutable and `Sendable`.
public struct SwipeDecoder: Sendable {
    public let lexicon: Lexicon
    public let model: NGramModel?
    public let personal: (any PersonalScoreProvider)?
    public let parameters: SwipeParameters
    /// Second lexicon searched together with the first (code-switching, M7-02); nil = single language.
    public let secondary: SecondaryLanguage?
    public let codeSwitch: CodeSwitchParameters

    private struct Letter: Sendable {
        var scalar: UInt32
        var c: KP
    }

    private let letters: [Letter]
    private let letterIndex: [UInt32: Int]
    private let keyW: Double
    private let keyH: Double
    private static let fineCount = 96
    /// How many of the best base-scored candidates get the (more expensive) personal-model treatment.
    private static let personalShortlist = 64

    public init(layout: KeyboardLayout, lexicon: Lexicon, model: NGramModel? = nil,
                personal: (any PersonalScoreProvider)? = nil, parameters: SwipeParameters = SwipeParameters(),
                secondary: SecondaryLanguage? = nil, codeSwitch: CodeSwitchParameters = CodeSwitchParameters()) {
        var raw: [(UInt32, CGRect)] = []
        var seen = Set<UInt32>()
        for key in layout.keys {
            guard case .letter(let s) = key.identity else { continue }
            let low = s.lowercased().unicodeScalars
            guard low.count == 1, key.frame.width > 0, key.frame.height > 0,
                  seen.insert(low.first!.value).inserted else { continue }
            raw.append((low.first!.value, key.frame))
        }
        let w = raw.isEmpty ? 1 : raw.reduce(0) { $0 + Double($1.1.width) } / Double(raw.count)
        let h = raw.isEmpty ? 1 : raw.reduce(0) { $0 + Double($1.1.height) } / Double(raw.count)
        keyW = w
        keyH = h
        letters = raw.map { Letter(scalar: $0.0, c: KP(x: Double($0.1.midX) / w, y: Double($0.1.midY) / h)) }
        var idx: [UInt32: Int] = [:]
        for (i, l) in letters.enumerated() { idx[l.scalar] = i }
        letterIndex = idx
        self.lexicon = lexicon
        self.model = model
        self.personal = personal
        self.parameters = parameters
        self.secondary = secondary
        self.codeSwitch = codeSwitch
    }

    // MARK: Decode

    /// - Parameters:
    ///   - points: the touch samples from touch-down to lift, in the container coordinates of the layout.
    ///   - context: up to two previous words as lexicon ids for the n-gram model.
    ///   - contextWords: the same previous words as text for the personal model (not stored or logged).
    ///   - secondaryContext: n-gram context in the secondary lexicon's ids and the language log-odds (ignored
    ///     without a secondary language).
    public func decode(points: [SwipePoint], context: LMContext = .none, contextWords: [String] = [],
                       secondaryContext: SecondaryContext = .neutral) -> SwipeDecodeResult {
        let p = parameters
        guard !letters.isEmpty, points.count >= 2 else { return .notASwipe }

        // 1. Key frame, length check, resampling.
        var kp: [KP] = []
        kp.reserveCapacity(points.count)
        var times: [Double] = []
        times.reserveCapacity(points.count)
        for s in points {
            kp.append(KP(x: s.x / keyW, y: s.y / keyH))
            times.append(s.t)
        }
        guard SwipeGeometry.pathLength(kp) >= p.minPathKeyWidths else { return .notASwipe }
        var fine: [KP] = []
        SwipeGeometry.resample(kp, count: Self.fineCount, into: &fine)
        let n = max(8, p.resampleCount)
        var gesture: [KP] = []
        SwipeGeometry.resample(kp, count: n, into: &gesture)
        let gShape = Self.normalized(gesture)

        // 2. Anchors (corners, dwells), away from the two ends.
        var anchors = SwipeGeometry.corners(kp, degrees: p.cornerDegrees)
        anchors += SwipeGeometry.dwells(kp, times: times, speed: p.dwellSpeed, minSeconds: p.dwellMinSeconds)
        let startPt = fine[0], endPt = fine[fine.count - 1]
        anchors.removeAll { $0.dist(startPt) < 0.5 || $0.dist(endPt) < 0.5 }

        // 3. Corridor: path samples near each letter key; start / end key candidates.
        var hits = [[Int32]](repeating: [], count: letters.count)
        var startOK = [Bool](repeating: false, count: letters.count)
        var endOK = [Bool](repeating: false, count: letters.count)
        var allowed: [Int] = []
        for (i, l) in letters.enumerated() {
            var h: [Int32] = []
            for (j, q) in fine.enumerated() where l.c.dist(q) <= p.corridorRadius { h.append(Int32(j)) }
            hits[i] = h
            startOK[i] = l.c.dist(startPt) <= p.endRadius
            endOK[i] = l.c.dist(endPt) <= p.endRadius
            if !h.isEmpty { allowed.append(i) }
        }

        // 4. Trie walk per language, 5. template scoring of lexicon candidates.
        struct Scored {
            var id: Lexicon.WordID?
            var word: String?
            var vertices: [Int]
            var spatial: Double
            var base: Double
            var score: Double
            var side: LexiconSide = .primary
            var prior: Double = 0
        }
        struct LangSide {
            var side: LexiconSide
            var lexicon: Lexicon
            var model: NGramModel?
            var context: LMContext
            var prior: Double
        }
        var langs = [LangSide(side: .primary, lexicon: lexicon, model: model, context: context, prior: 0)]
        if let secondary {
            langs[0].prior = codeSwitch.priorWeight * secondaryContext.logPrior(.primary)
            langs.append(LangSide(side: .secondary, lexicon: secondary.lexicon, model: secondary.model,
                                  context: secondaryContext.lm,
                                  prior: codeSwitch.priorWeight * secondaryContext.logPrior(.secondary)))
        }
        let dual = langs.count > 1
        var scored: [Scored] = []
        var nodesVisited = 0
        var truncated = false
        var template: [KP] = []
        var poly: [KP] = []
        for lang in langs {
            var search = Search(lexicon: lang.lexicon, letters: letters, hits: hits, startOK: startOK, endOK: endOK,
                                allowed: allowed, maxVisits: p.maxNodeVisits, maxLength: p.maxWordLength)
            search.visit(cursor: lang.lexicon.root, pos: 0, depth: 0)
            nodesVisited += search.visits
            truncated = truncated || search.truncated
            scored.reserveCapacity(scored.count + search.cands.count)
            for c in search.cands {
                let verts = Array(search.pool[c.offset..<(c.offset + c.count)].map { Int($0) })
                let sp = spatialLogLikelihood(vertices: verts, gesture: gesture, gShape: gShape, anchors: anchors,
                                              poly: &poly, template: &template)
                let base = baseLog(c.id, lang.lexicon, lang.model, lang.context)
                scored.append(Scored(id: c.id, word: nil, vertices: verts, spatial: sp, base: base,
                                     score: sp + p.lmWeight * (base + lang.prior), side: lang.side, prior: lang.prior))
            }
        }
        if dual {
            // A word in both lexicons was scored twice (same template): keep the better reading.
            var best: [String: Int] = [:]
            var drop = Set<Int>()
            for i in scored.indices {
                let word = langs[Int(scored[i].side.rawValue)].lexicon.word(of: scored[i].id!)
                if let j = best[word] {
                    if scored[i].score > scored[j].score { drop.insert(j); best[word] = i } else { drop.insert(i) }
                } else {
                    best[word] = i
                }
            }
            if !drop.isEmpty {
                scored = scored.indices.filter { !drop.contains($0) }.map { scored[$0] }
            }
        }

        // 6. Personal model: shortlist, forgotten words out, mixed LM, and personal-only words.
        var usedPersonal = Set<Int>()   // indices into `scored`
        var mixed: [Int: Double] = [:]
        if let personal {
            scored.sort { $0.score != $1.score ? $0.score > $1.score : ($0.id ?? .max) < ($1.id ?? .max) }
            var keep: [Scored] = []
            for (i, var s) in scored.enumerated() {
                if i >= Self.personalShortlist { keep.append(s); continue }
                let word = langs[Int(s.side.rawValue)].lexicon.word(of: s.id!)
                if personal.isForgotten(word) { continue }
                s.word = word
                if let ps = personal.score(word: word, context: contextWords) {
                    let m = PersonalInterpolation.mix(baseLogProb: s.base, personal: ps)
                    s.score = s.spatial + p.lmWeight * (m + s.prior)
                    keep.append(s)
                    usedPersonal.insert(keep.count - 1)
                    mixed[keep.count - 1] = m
                } else {
                    keep.append(s)
                }
            }
            scored = keep
            if p.personalOOVPerLetter > 0 {
                var seenWords = Set<String>()
                for i in allowed where startOK[i] {
                    let prefix = String(Unicode.Scalar(letters[i].scalar) ?? "?")
                    for pc in personal.completions(prefix: prefix, limit: p.personalOOVPerLetter) {
                        let word = pc.word.lowercased()
                        guard lexicon.lookup(word) == nil, secondary?.lexicon.lookup(word) == nil,
                              !personal.isForgotten(word),
                              seenWords.insert(word).inserted,
                              let verts = vertices(for: word, hits: hits, startOK: startOK, endOK: endOK)
                        else { continue }
                        guard let ps = personal.score(word: word, context: contextWords) else { continue }
                        let sp = spatialLogLikelihood(vertices: verts, gesture: gesture, gShape: gShape,
                                                      anchors: anchors, poly: &poly, template: &template)
                        let m = PersonalInterpolation.mix(baseLogProb: p.oovLogProbability, personal: ps)
                        let prior = langs.map(\.prior).max() ?? 0
                        scored.append(Scored(id: nil, word: word, vertices: verts, spatial: sp, base: p.oovLogProbability,
                                             score: sp + p.lmWeight * (m + prior), prior: prior))
                        usedPersonal.insert(scored.count - 1)
                        mixed[scored.count - 1] = m
                    }
                }
            }
        }

        guard !scored.isEmpty else {
            return SwipeDecodeResult(candidates: [], confidence: 0, margin: 0, scoredCount: 0,
                                     nodesVisited: nodesVisited, truncated: truncated,
                                     anchorCount: anchors.count, isSwipe: true)
        }

        // 7. Rank and posterior.
        var order = Array(scored.indices)
        order.sort {
            let a = scored[$0], b = scored[$1]
            if a.score != b.score { return a.score > b.score }
            if (a.id ?? .max) != (b.id ?? .max) { return (a.id ?? .max) < (b.id ?? .max) }
            if a.side != b.side { return a.side < b.side }
            return ($0) < ($1)
        }
        let maxScore = scored[order[0]].score
        var z = 0.0
        for s in scored { z += exp(s.score - maxScore) }
        let confidence = 1 / z
        let second = order.count > 1 ? exp(scored[order[1]].score - maxScore) / z : 0
        var out: [SwipeCandidate] = []
        for i in order.prefix(p.maxCandidates) {
            let s = scored[i]
            let word = s.word ?? langs[Int(s.side.rawValue)].lexicon.word(of: s.id!)
            out.append(SwipeCandidate(word: word, wordID: s.id, score: s.score, spatial: s.spatial,
                                      language: mixed[i] ?? s.base, usedPersonal: usedPersonal.contains(i), side: s.side))
        }
        return SwipeDecodeResult(candidates: out, confidence: confidence, margin: confidence - second,
                                 scoredCount: scored.count, nodesVisited: nodesVisited, truncated: truncated,
                                 anchorCount: anchors.count, isSwipe: true)
    }

    // MARK: Scoring

    private func baseLog(_ id: Lexicon.WordID, _ lexicon: Lexicon, _ model: NGramModel?, _ ctx: LMContext) -> Double {
        guard let model else { return lexicon.logProbability(of: id) }
        let m = parameters.lmUnigramMix
        guard m > 0, ctx.recent != nil else { return model.logProbability(id, context: ctx) }
        // Interpolate with the unigram so a rarely seen continuation of a seen context (sharp trigram backoff in
        // the small Hinglish corpus: -20 nats for a common word) cannot veto a clean swipe.
        let p = (1 - m) * model.probability(id, context: ctx) + m * model.unigramProbability(id)
        return log(max(p, 1e-30))
    }

    /// Centroid-centred, scale-normalized copy (scale = larger bounding-box side, floored at 0.25 key).
    private static func normalized(_ pts: [KP]) -> [KP] {
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        var cx = 0.0, cy = 0.0
        for q in pts {
            minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y)
            cx += q.x; cy += q.y
        }
        cx /= Double(pts.count); cy /= Double(pts.count)
        let s = max(maxX - minX, maxY - minY, 0.25)
        return pts.map { KP(x: ($0.x - cx) / s, y: ($0.y - cy) / s) }
    }

    private func spatialLogLikelihood(vertices: [Int], gesture: [KP], gShape: [KP], anchors: [KP],
                                      poly: inout [KP], template: inout [KP]) -> Double {
        let p = parameters
        poly.removeAll(keepingCapacity: true)
        for v in vertices { poly.append(letters[v].c) }
        SwipeGeometry.resample(poly, count: gesture.count, into: &template)
        let tShape = Self.normalized(template)
        var shape = 0.0, loc = 0.0
        for i in 0..<gesture.count {
            shape += gShape[i].dist(tShape[i])
            loc += max(0, gesture[i].dist(template[i]) - p.locationTolerance)
        }
        shape /= Double(gesture.count)
        loc /= Double(gesture.count)
        var anchorPenalty = 0.0
        for a in anchors {
            var d = Double.infinity
            for v in vertices { d = min(d, a.dist(letters[v].c)) }
            let c = min(d, p.anchorCap) / p.anchorSigma
            anchorPenalty += c * c
        }
        let sz = shape / p.shapeSigma, lz = loc / p.locationSigma
        // Endpoints: the touch-down and lift keys are the most certain evidence in a swipe, but averaged over the
        // whole path they are diluted; charge them directly beyond a free radius.
        var endPenalty = 0.0
        if p.endpointWeight > 0, let g0 = gesture.first, let g1 = gesture.last, let t0 = template.first, let t1 = template.last {
            let e0 = max(0, g0.dist(t0) - p.endpointTolerance) / p.endpointSigma
            let e1 = max(0, g1.dist(t1) - p.endpointTolerance) / p.endpointSigma
            endPenalty = e0 * e0 + e1 * e1
        }
        return -0.5 * (sz * sz + lz * lz + p.anchorWeight * anchorPenalty + p.endpointWeight * endPenalty)
    }

    /// Letter-key sequence (consecutive repeats collapsed) of `word` if it passes the same corridor / order / end
    /// tests as the trie walk; nil otherwise.
    private func vertices(for word: String, hits: [[Int32]], startOK: [Bool], endOK: [Bool]) -> [Int]? {
        var seq: [Int] = []
        var pos = 0
        var count = 0
        for sc in word.unicodeScalars {
            guard let li = letterIndex[sc.value] else { return nil }
            if count == 0, !startOK[li] { return nil }
            guard let hit = Search.lowerBound(hits[li], pos) else { return nil }
            pos = Int(hits[li][hit])
            if seq.last != li { seq.append(li) }
            count += 1
        }
        guard count <= parameters.maxWordLength, seq.count >= 2, let last = seq.last, endOK[last] else { return nil }
        return seq
    }

    // MARK: Trie search

    private struct Cand {
        var id: Lexicon.WordID
        var offset: Int
        var count: Int
    }

    private struct Search {
        let lexicon: Lexicon
        let letters: [Letter]
        let hits: [[Int32]]
        let startOK: [Bool]
        let endOK: [Bool]
        let allowed: [Int]
        let maxVisits: Int
        let maxLength: Int
        var stack: [Int] = []
        var cands: [Cand] = []
        var pool: [Int32] = []
        var visits = 0
        var truncated = false

        init(lexicon: Lexicon, letters: [Letter], hits: [[Int32]], startOK: [Bool], endOK: [Bool],
             allowed: [Int], maxVisits: Int, maxLength: Int) {
            self.lexicon = lexicon; self.letters = letters; self.hits = hits; self.startOK = startOK
            self.endOK = endOK; self.allowed = allowed; self.maxVisits = maxVisits; self.maxLength = maxLength
        }

        /// Index of the first element >= `value`, nil when none.
        static func lowerBound(_ a: [Int32], _ value: Int) -> Int? {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if Int(a[mid]) < value { lo = mid + 1 } else { hi = mid }
            }
            return lo < a.count ? lo : nil
        }

        mutating func visit(cursor: TrieCursor, pos: Int, depth: Int) {
            for li in allowed {
                if truncated { return }
                if depth == 0, !startOK[li] { continue }
                guard let child = lexicon.child(of: cursor, label: letters[li].scalar),
                      let hit = Search.lowerBound(hits[li], pos) else { continue }
                visits += 1
                if visits > maxVisits { truncated = true; return }
                stack.append(li)
                if endOK[li], let w = lexicon.wordID(at: child) {
                    let off = pool.count
                    var last = -1
                    for k in stack where k != last { pool.append(Int32(k)); last = k }
                    if pool.count - off >= 2 {
                        cands.append(Cand(id: w, offset: off, count: pool.count - off))
                    } else {
                        pool.removeLast(pool.count - off)
                    }
                }
                if depth + 1 < maxLength, lexicon.hasChildren(child) {
                    visit(cursor: child, pos: Int(hits[li][hit]), depth: depth + 1)
                }
                stack.removeLast()
            }
        }
    }
}
