import CoreGraphics
import Foundation
import IBoardEngine
import IBoardLayout

/// SYNTHETIC swipe trace generator (M4-04). It interpolates the key centres of a word with seeded per-key jitter,
/// corner cutting, overshoot, speed variation and occasional dwells. The decoder and the generator are written by
/// the same author and share the same idea of a swipe, so numbers from these traces are regression guards and
/// optimistic estimates, never evidence of accuracy on real fingers.
struct SwipeProfile {
    var name: String
    /// Gaussian offset of each waypoint from its key centre, in key sizes.
    var jitter: Double
    /// Corner cut distance as a fraction of the adjacent segments (capped at `cutCap` key widths).
    var cutFraction: ClosedRange<Double>
    var cutCap = 0.6
    /// Overshoot past a turning waypoint, key widths.
    var overshoot: ClosedRange<Double>
    /// Log-normal sigma of the speed multiplier (smooth random walk along the path).
    var speedSigma: Double
    /// Probability of a short dwell at each waypoint.
    var dwellProbability: Double
    /// Mean speed in key widths per second.
    var meanSpeed: Double

    static let careful = SwipeProfile(name: "careful", jitter: 0.12, cutFraction: 0...0.1, overshoot: 0...0.05,
                                      speedSigma: 0.2, dwellProbability: 0.1, meanSpeed: 7)
    static let normal = SwipeProfile(name: "normal", jitter: 0.22, cutFraction: 0...0.25, overshoot: 0...0.15,
                                     speedSigma: 0.35, dwellProbability: 0.15, meanSpeed: 9)
    static let sloppy = SwipeProfile(name: "sloppy", jitter: 0.32, cutFraction: 0.1...0.4, overshoot: 0...0.3,
                                     speedSigma: 0.5, dwellProbability: 0.2, meanSpeed: 12)
    static let all = [careful, normal, sloppy]
}

enum SwipeSynth {
    /// Samples (60 Hz nominal) of a swipe over `word`'s letters in `layout`. nil if a letter has no key.
    static func trace(_ word: String, layout: KeyboardLayout, profile: SwipeProfile,
                      rng: inout SplitMix64) -> [SwipePoint]? {
        var keys: [KeyboardKey] = []
        for ch in word where ch != "'" && ch != "\u{2019}" {   // apostrophes are not swipe keys
            guard let k = layout.firstKey(.letter(String(ch))) else { return nil }
            if keys.last?.id != k.id { keys.append(k) }
        }
        guard keys.count >= 2 else { return nil }
        let keyW = Double(keys[0].frame.width)

        // Waypoints with jitter.
        var wp: [CGPoint] = keys.map { k in
            CGPoint(x: Double(k.frame.midX) + rng.gaussian() * profile.jitter * Double(k.frame.width),
                    y: Double(k.frame.midY) + rng.gaussian() * profile.jitter * Double(k.frame.height))
        }
        func unit(_ a: CGPoint, _ b: CGPoint) -> (Double, Double, Double) {
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let l = max((dx * dx + dy * dy).squareRoot(), 1e-9)
            return (dx / l, dy / l, l)
        }
        func uniform(_ r: ClosedRange<Double>) -> Double {
            r.lowerBound + (r.upperBound - r.lowerBound) * Double(rng.next() >> 11) / Double(1 << 53)
        }
        // Overshoot: push turning interior waypoints further along the incoming direction.
        if wp.count > 2 {
            for i in 1..<(wp.count - 1) {
                let (ux, uy, _) = unit(wp[i - 1], wp[i])
                let o = uniform(profile.overshoot) * keyW
                wp[i] = CGPoint(x: Double(wp[i].x) + ux * o, y: Double(wp[i].y) + uy * o)
            }
        }
        // Dense polyline with corner cutting (quadratic Bezier around interior waypoints).
        var dense: [CGPoint] = [wp[0]]
        var vertexAt: [Int] = [0]   // index in `dense` of each waypoint (for dwells)
        if wp.count > 2 {
            for i in 1..<(wp.count - 1) {
                let (_, _, l0) = unit(wp[i - 1], wp[i])
                let (_, _, l1) = unit(wp[i], wp[i + 1])
                let cut = min(uniform(profile.cutFraction) * min(l0, l1), profile.cutCap * keyW)
                let a = lerp(wp[i], wp[i - 1], cut / l0), b = lerp(wp[i], wp[i + 1], cut / l1)
                for s in 0...6 {
                    let t = Double(s) / 6
                    let x = (1 - t) * (1 - t) * Double(a.x) + 2 * (1 - t) * t * Double(wp[i].x) + t * t * Double(b.x)
                    let y = (1 - t) * (1 - t) * Double(a.y) + 2 * (1 - t) * t * Double(wp[i].y) + t * t * Double(b.y)
                    dense.append(CGPoint(x: x, y: y))
                    if s == 3 { vertexAt.append(dense.count - 1) }
                }
            }
        }
        dense.append(wp[wp.count - 1])
        vertexAt.append(dense.count - 1)
        var dwellAt = Set(vertexAt.filter { _ in uniform(0...1) < profile.dwellProbability })

        // Walk the dense path with a varying speed, sampling at ~60 Hz.
        var out: [SwipePoint] = []
        var t = 0.0
        var logSpeed = 0.0
        var seg = 0
        var pos = dense[0]
        out.append(SwipePoint(pos, t: t))
        while seg < dense.count - 1 {
            let dt = (1.0 / 60) * (1 + 0.1 * rng.gaussian())
            logSpeed = 0.9 * logSpeed + 0.44 * profile.speedSigma * rng.gaussian()
            if dwellAt.remove(seg) != nil {
                // Dwell: a few near-stationary samples.
                let n = 3 + Int(rng.next() % 3)
                for _ in 0..<n {
                    t += 1.0 / 60
                    out.append(SwipePoint(x: Double(pos.x) + rng.gaussian() * 0.02 * keyW,
                                          y: Double(pos.y) + rng.gaussian() * 0.02 * keyW, t: t))
                }
            }
            var travel = profile.meanSpeed * exp(logSpeed) * keyW * max(dt, 0.005)
            while travel > 0, seg < dense.count - 1 {
                let (ux, uy, l) = unit(pos, dense[seg + 1])
                if l <= travel {
                    travel -= l
                    pos = dense[seg + 1]
                    seg += 1
                } else {
                    pos = CGPoint(x: Double(pos.x) + ux * travel, y: Double(pos.y) + uy * travel)
                    travel = 0
                }
            }
            t += max(dt, 0.005)
            out.append(SwipePoint(x: Double(pos.x) + rng.gaussian() * 0.03 * keyW,
                                  y: Double(pos.y) + rng.gaussian() * 0.03 * keyW, t: t))
        }
        return out
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ f: Double) -> CGPoint {
        CGPoint(x: Double(a.x) + (Double(b.x) - Double(a.x)) * f, y: Double(a.y) + (Double(b.y) - Double(a.y)) * f)
    }
}

/// Top-1 / top-3 scorer over synthetic traces. Labelled SYNTHETIC in every printout.
struct SwipeScore {
    var total = 0
    var top1 = 0
    var top3 = 0
    var inCandidates = 0     // truth reached template scoring at all
    var confidentWrong = 0   // wrong top-1 with posterior >= 0.9

    var top1Rate: Double { total == 0 ? 0 : Double(top1) / Double(total) }
    var top3Rate: Double { total == 0 ? 0 : Double(top3) / Double(total) }

    /// Prompts such as "dont" or "thats" mean the contraction: when the plain spelling is not a lexicon word but exactly
    /// one apostrophe insertion is, the contraction is the intended truth (the keyboard should type it).
    static func canonicalTruth(_ word: String, in lexicon: Lexicon) -> String {
        guard !word.contains("'"), lexicon.lookup(word) == nil else { return word }
        let chars = Array(word)
        for i in 1..<max(1, chars.count) {
            let cand = String(chars[..<i]) + "'" + String(chars[i...])
            if lexicon.lookup(cand) != nil { return cand }
        }
        return word
    }

    mutating func add(truth: String, result: SwipeDecodeResult) {
        total += 1
        let words = result.candidates.map(\.word)
        if words.first == truth { top1 += 1 }
        else if let c = result.candidates.first, c.score.isFinite, result.confidence >= 0.9 { confidentWrong += 1 }
        if words.prefix(3).contains(truth) { top3 += 1 }
        if words.contains(truth) { inCandidates += 1 }
    }

    func line(_ label: String) -> String {
        String(format: "SYNTHETIC %@: n=%d top-1 %.1f%% top-3 %.1f%% (truth in returned list %.1f%%, confident-wrong %d)",
               label, total, top1Rate * 100, top3Rate * 100,
               total == 0 ? 0 : Double(inCandidates) / Double(total) * 100, confidentWrong)
    }
}
