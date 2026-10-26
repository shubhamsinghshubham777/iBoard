import Foundation

/// Pure path geometry for the swipe decoder, in the "key frame" (x / mean key width, y / mean key height, so one
/// unit is about one key). No allocation-free promises, but everything is O(points).
struct KP: Sendable, Equatable {
    var x: Double
    var y: Double
    @inline(__always) func dist(_ o: KP) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
}

enum SwipeGeometry {
    static func pathLength(_ p: [KP]) -> Double {
        var l = 0.0
        if p.count > 1 { for i in 1..<p.count { l += p[i - 1].dist(p[i]) } }
        return l
    }

    /// `n` points equally spaced along the polyline (both ends included). `n >= 2`. A zero-length path repeats its point.
    static func resample(_ p: [KP], count n: Int, into out: inout [KP]) {
        out.removeAll(keepingCapacity: true)
        guard let first = p.first else { return }
        let total = pathLength(p)
        guard total > 1e-12, p.count > 1 else {
            for _ in 0..<n { out.append(first) }
            return
        }
        let step = total / Double(n - 1)
        out.append(first)
        var seg = 1
        var segStart = p[0]
        var next = step         // arc length of the next sample
        var walked = 0.0        // arc length at segStart
        while out.count < n - 1, seg < p.count {
            let end = p[seg]
            let segLen = segStart.dist(end)
            if walked + segLen >= next - 1e-12, segLen > 0 {
                let f = (next - walked) / segLen
                out.append(KP(x: segStart.x + (end.x - segStart.x) * f, y: segStart.y + (end.y - segStart.y) * f))
                next += step
            } else {
                walked += segLen
                segStart = end
                seg += 1
            }
        }
        while out.count < n { out.append(p[p.count - 1]) }
    }

    /// Distance from `q` to the nearest point of the sampled path.
    static func distance(from q: KP, to path: [KP]) -> Double {
        var best = Double.infinity
        for p in path { best = min(best, q.dist(p)) }
        return best
    }

    /// Corner anchors: local maxima of the turning angle on a path resampled at ~0.35 key spacing.
    static func corners(_ p: [KP], degrees: Double) -> [KP] {
        let total = pathLength(p)
        let n = min(200, max(9, Int(total / 0.35) + 1))
        var r: [KP] = []
        resample(p, count: n, into: &r)
        let w = 2
        guard n > 2 * w + 1 else { return [] }
        var angle = [Double](repeating: 0, count: n)
        for i in w..<(n - w) {
            let ax = r[i].x - r[i - w].x, ay = r[i].y - r[i - w].y
            let bx = r[i + w].x - r[i].x, by = r[i + w].y - r[i].y
            let la = (ax * ax + ay * ay).squareRoot(), lb = (bx * bx + by * by).squareRoot()
            guard la > 1e-9, lb > 1e-9 else { continue }
            let c = max(-1, min(1, (ax * bx + ay * by) / (la * lb)))
            angle[i] = acos(c) * 180 / .pi
        }
        var out: [KP] = []
        for i in w..<(n - w) where angle[i] >= degrees {
            var isMax = true
            for j in max(w, i - 3)...min(n - w - 1, i + 3) where j != i {
                if angle[j] > angle[i] || (angle[j] == angle[i] && j < i) { isMax = false; break }
            }
            if isMax { out.append(r[i]) }
        }
        return out
    }

    /// Dwell anchors: runs of consecutive samples slower than `speed` (key sizes per second) lasting at least
    /// `minSeconds`. The anchor is the mean position of the run. Needs strictly increasing timestamps.
    static func dwells(_ p: [KP], times: [Double], speed: Double, minSeconds: Double) -> [KP] {
        guard p.count > 2, p.count == times.count, times[times.count - 1] > times[0] else { return [] }
        var out: [KP] = []
        var i = 0
        while i < p.count - 1 {
            var j = i
            while j < p.count - 1 {
                let dt = times[j + 1] - times[j]
                if dt <= 0 || p[j].dist(p[j + 1]) / dt >= speed { break }
                j += 1
            }
            if j > i, times[j] - times[i] >= minSeconds {
                var sx = 0.0, sy = 0.0
                for k in i...j { sx += p[k].x; sy += p[k].y }
                let c = Double(j - i + 1)
                out.append(KP(x: sx / c, y: sy / c))
                i = j + 1
            } else {
                i = max(j, i + 1)
            }
        }
        return out
    }
}
