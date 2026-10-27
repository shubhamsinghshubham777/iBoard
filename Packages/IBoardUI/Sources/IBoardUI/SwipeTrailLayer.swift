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

/// The swipe trail (M4-01, redesigned): a thin, smooth comet. The capture's resampled polyline is split into
/// `chunkCount` consecutive pieces, each its own `CAShapeLayer` whose alpha, width and colour step from a faint,
/// hairline tail (cooler hue) to a bright head in the theme's trail colour. Smooth because every piece is drawn as
/// quadratic curves through midpoints and neighbouring pieces share an end point.
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
    private var shown = false

    public override init() {
        super.init()
        zPosition = 1000 // above every key layer
        actions = ["opacity": NSNull(), "hidden": NSNull(), "sublayers": NSNull()]
        isHidden = true
        for i in 0..<Self.chunkCount {
            let l = CAShapeLayer()
            l.fillColor = nil
            // Butt caps inside the trail: round caps of translucent neighbours overlap into visible dots.
            l.lineCap = i == Self.chunkCount - 1 ? .round : .butt
            l.lineJoin = .round
            l.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "hidden": NSNull()]
            addSublayer(l)
            chunks.append(l)
        }
        applyStyle()
    }

    public override init(layer: Any) { super.init(layer: layer) }
    public required init?(coder: NSCoder) { fatalError("unused") }

    private func applyStyle() {
        let c = trailStyle.color
        let stops = SwipeTrailGradient.stops(count: chunks.count, head: (c.red, c.green, c.blue), width: trailStyle.width * 0.8)
        for (l, s) in zip(chunks, stops) {
            l.strokeColor = CGColor(srgbRed: s.red, green: s.green, blue: s.blue, alpha: s.alpha * c.alpha)
            l.lineWidth = CGFloat(s.width)
        }
    }

    private static func smoothPath(_ pts: ArraySlice<CGPoint>) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        let a = Array(pts)
        if a.count == 2 {
            path.addLine(to: a[1])
        } else if a.count > 2 {
            for i in 1..<a.count - 1 {
                path.addQuadCurve(to: CGPoint(x: (a[i].x + a[i + 1].x) / 2, y: (a[i].y + a[i + 1].y) / 2), control: a[i])
            }
            path.addLine(to: a[a.count - 1])
        }
        return path
    }

    /// Redraw from the polyline (tail first, last point = finger).
    @MainActor
    public func update(points: [CGPoint]) {
        guard points.count > 1 else { return }
        removeAnimation(forKey: Self.fadeKey)
        let n = points.count
        let per = max(2, Int((Double(n - 1) / Double(chunks.count)).rounded(.up)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in chunks.enumerated() {
            let from = i * per
            let to = min(n - 1, from + per) // the last point is shared with the next piece
            if from >= n - 1 { l.path = nil; continue }
            l.path = Self.smoothPath(points[from...to])
        }
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
        isHidden = true
        shown = false
        opacity = 1
        CATransaction.commit()
    }
}
#endif
