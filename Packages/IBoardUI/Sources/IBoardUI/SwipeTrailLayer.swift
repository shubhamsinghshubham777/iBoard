import Foundation

/// Gradient for the trail, oldest chunk first: `count` (color, width) pairs from a transparent hairline tail to the
/// bright head. Pure, so it can be tested without UIKit state.
public enum SwipeTrailGradient {
    public struct Stop: Equatable, Sendable {
        public var red: Double, green: Double, blue: Double, alpha: Double
        public var width: Double
    }

    /// The tail drifts toward a cooler, lighter hue so the trail reads as a gradient even on a plain keyboard;
    /// alpha and width grow with an ease-out curve toward the head (t = 0 tail, t = 1 head).
    public static func stops(count: Int, head: (red: Double, green: Double, blue: Double), width: Double) -> [Stop] {
        guard count > 0 else { return [] }
        let tail = (red: head.red * 0.45 + 0.55 * 0.62, green: head.green * 0.45 + 0.55 * 0.45, blue: head.blue * 0.45 + 0.55 * 1.0)
        return (0..<count).map { i in
            let t = count == 1 ? 1 : Double(i) / Double(count - 1)
            let e = t * t * (3 - 2 * t) // smoothstep
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * e }
            return Stop(red: mix(tail.red, head.red), green: mix(tail.green, head.green), blue: mix(tail.blue, head.blue),
                        alpha: 0.04 + 0.92 * pow(t, 1.4), width: width * (0.3 + 0.7 * pow(t, 0.8)))
        }
    }
}

#if canImport(UIKit)
import UIKit
import IBoardTheme

/// The swipe trail (M4-01, redesigned twice): a thick "ink comet". The capture's resampled polyline is split into
/// `chunkCount` consecutive pieces, each its own `CAShapeLayer` whose alpha, width and colour step from a faint,
/// thin tail (cooler hue) to a bright, thick head in the theme's trail colour (head width = 3 x the theme width, 12 pt
/// for the default 4). Each piece also has a wider, faint halo stroke (same path object) for a soft glow, and a bead
/// marks the fingertip. Smooth because every piece is drawn as quadratic curves through midpoints and neighbouring
/// pieces share an end point.
///
/// Cost: at most `chunkCount` small paths rebuilt per touch-move; nothing allocated per key. With Reduce Motion the
/// trail is still drawn while the finger is down (it is the direct echo of the finger) but disappears at once on
/// lift instead of fading. Touched from the main thread only.
public final class SwipeTrailLayer: CALayer {
    public static let fadeKey = "iboard.trailFade"
    static let chunkCount = 14

    public var trailStyle = SwipeTrailStyle(color: ThemeColor(hex: 0x007AFF)) {
        didSet { applyStyle() }
    }

    private var chunks: [CAShapeLayer] = []
    private var halos: [CAShapeLayer] = []
    private let bead = CAShapeLayer()
    private var shown = false

    public override init() {
        super.init()
        zPosition = 1000 // above every key layer
        actions = ["opacity": NSNull(), "hidden": NSNull(), "sublayers": NSNull()]
        isHidden = true
        for _ in 0..<Self.chunkCount {
            let h = CAShapeLayer()
            h.strokeColor = nil
            h.actions = ["path": NSNull(), "fillColor": NSNull(), "hidden": NSNull()]
            addSublayer(h)
            halos.append(h)
        }
        for _ in 0..<Self.chunkCount {
            let l = CAShapeLayer()
            l.strokeColor = nil
            l.actions = ["path": NSNull(), "fillColor": NSNull(), "hidden": NSNull()]
            addSublayer(l)
            chunks.append(l)
        }
        bead.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "position": NSNull(), "hidden": NSNull()]
        addSublayer(bead)
        applyStyle()
    }

    public override init(layer: Any) { super.init(layer: layer) }
    public required init?(coder: NSCoder) { fatalError("unused") }

    private func applyStyle() {
        let c = trailStyle.color
        let headWidth = max(trailStyle.width, 2) * 3
        let stops = SwipeTrailGradient.stops(count: chunks.count, head: (c.red, c.green, c.blue), width: headWidth)
        for (i, s) in stops.enumerated() {
            chunks[i].fillColor = CGColor(srgbRed: s.red, green: s.green, blue: s.blue, alpha: s.alpha * 0.9 * c.alpha)
            halos[i].fillColor = CGColor(srgbRed: s.red, green: s.green, blue: s.blue, alpha: s.alpha * 0.2 * c.alpha)
        }
        let r = CGFloat(headWidth) * 0.62
        bead.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        bead.fillColor = CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        bead.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)
        bead.lineWidth = 2
    }

    /// Closed polygon along `pts[from...to]` with the given half widths: left edge forward, right edge back. Pieces that
    /// share an end index share their edge points, so neighbouring pieces meet without a seam or an overlap.
    private static func ribbon(left: [CGPoint], right: [CGPoint], from: Int, to: Int) -> CGPath {
        let path = CGMutablePath()
        path.move(to: left[from])
        for i in (from + 1)...to { path.addLine(to: left[i]) }
        for i in stride(from: to, through: from, by: -1) { path.addLine(to: right[i]) }
        path.closeSubpath()
        return path
    }

    /// Redraw from the polyline (tail first, last point = finger): a ribbon that tapers from a thin tail to the full
    /// head width, cut into `chunkCount` pieces for the alpha / hue gradient.
    @MainActor
    public func update(points: [CGPoint]) {
        guard points.count > 1 else { return }
        removeAnimation(forKey: Self.fadeKey)
        let n = points.count
        let headWidth = CGFloat(max(trailStyle.width, 2) * 3)
        // Edge points (body and halo) from averaged normals.
        var left = [CGPoint](), right = [CGPoint](), hLeft = [CGPoint](), hRight = [CGPoint]()
        left.reserveCapacity(n); right.reserveCapacity(n); hLeft.reserveCapacity(n); hRight.reserveCapacity(n)
        for i in 0..<n {
            let a = points[max(0, i - 1)], b = points[min(n - 1, i + 1)]
            var dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.0001)
            dx /= len; dy /= len
            let t = CGFloat(i) / CGFloat(n - 1)
            let w = headWidth * (0.16 + 0.84 * pow(t, 0.9)) / 2
            let nx = -dy, ny = dx, p = points[i]
            left.append(CGPoint(x: p.x + nx * w, y: p.y + ny * w)); right.append(CGPoint(x: p.x - nx * w, y: p.y - ny * w))
            hLeft.append(CGPoint(x: p.x + nx * w * 1.9, y: p.y + ny * w * 1.9)); hRight.append(CGPoint(x: p.x - nx * w * 1.9, y: p.y - ny * w * 1.9))
        }
        let per = max(1, Int((Double(n - 1) / Double(chunks.count)).rounded(.up)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in chunks.enumerated() {
            let from = i * per
            let to = min(n - 1, from + per) // the last point is shared with the next piece
            if from >= n - 1 { l.path = nil; halos[i].path = nil; continue }
            l.path = Self.ribbon(left: left, right: right, from: from, to: to)
            halos[i].path = Self.ribbon(left: hLeft, right: hRight, from: from, to: to)
        }
        bead.position = points[n - 1]
        bead.isHidden = false
        opacity = 1
        isHidden = false
        shown = true
        CATransaction.commit()
    }

    /// Finger lifted (or cancelled): fade out over `trailStyle.fadeDuration`, or vanish at once under Reduce Motion.
    @MainActor
    public func finish(reduceMotion: Bool? = nil) {
        guard !isHidden else { return }
        if reduceMotion ?? UIAccessibility.isReduceMotionEnabled || trailStyle.fadeDuration <= 0 {
            clear()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = trailStyle.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 0
        add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
    }

    /// Remove the trail immediately.
    @MainActor
    public func clear() {
        removeAnimation(forKey: Self.fadeKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in chunks { l.path = nil }
        for h in halos { h.path = nil }
        bead.isHidden = true
        isHidden = true
        shown = false
        opacity = 1
        CATransaction.commit()
    }
}
#endif
