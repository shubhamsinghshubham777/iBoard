import CoreGraphics
import Foundation
import IBoardEngine
import IBoardLayout

/// Deterministic generator (SplitMix64) so synthetic traces are reproducible.
struct TraceRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func gauss() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

enum TraceFixtures {
    static let layout = LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters)

    static func centre(_ letter: String, in layout: KeyboardLayout = layout) -> CGPoint {
        let f = layout.firstKey(.letter(letter))!.frame
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// A plausible swipe through the letters of `word`: waypoints at key centres with Gaussian jitter (in key
    /// sizes), linear interpolation at 60 Hz with a random speed (key widths per second). Words with fewer than 2
    /// distinct consecutive letters return nil.
    static func swipe(_ word: String, layout: KeyboardLayout = layout, jitter: Double = 0.2,
                      keysPerSecond: Double = 6, rng: inout TraceRNG, startTime: Double = 0) -> [SwipePoint]? {
        var way: [CGPoint] = []
        var last: Character?
        let a = layout.firstKey(.letter("a"))!.frame
        let kw = Double(a.width), kh = Double(a.height)
        for ch in word where ch != last {
            guard ch.isLetter, ch.isASCII else { return nil }
            let c = centre(String(ch).lowercased(), in: layout)
            way.append(CGPoint(x: Double(c.x) + rng.gauss() * jitter * kw, y: Double(c.y) + rng.gauss() * jitter * kh))
            last = ch
        }
        guard way.count >= 2 else { return nil }
        let speed = keysPerSecond * kw * rng.range(0.7, 1.3) // pt / s
        let dt = 1.0 / 60
        var out: [SwipePoint] = []
        var t = startTime
        out.append(SwipePoint(x: Double(way[0].x), y: Double(way[0].y), t: t))
        for i in 1..<way.count {
            let p = way[i - 1], q = way[i]
            let len = Double(hypot(q.x - p.x, q.y - p.y))
            let steps = max(1, Int((len / (speed * dt)).rounded(.up)))
            for s in 1...steps {
                let f = Double(s) / Double(steps)
                t += dt
                out.append(SwipePoint(x: Double(p.x) + Double(q.x - p.x) * f, y: Double(p.y) + Double(q.y - p.y) * f, t: t))
            }
        }
        return out
    }

    /// Letter-only words of 3...8 letters over the alphabet, seeded: enough variety for gesture-matrix tests.
    static func syntheticWords(count: Int, seed: UInt64) -> [String] {
        var rng = TraceRNG(seed: seed)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var words: [String] = []
        while words.count < count {
            let n = 3 + Int(rng.unit() * 6)
            var w = ""
            for _ in 0..<n { w.append(letters[Int(rng.unit() * 26)]) }
            if Set(w).count >= 2 { words.append(w) }
        }
        return words
    }
}
