#if canImport(UIKit)
import UIKit
import IBoardTheme

/// The swipe trail (M4-01): one `CAShapeLayer`, stroked in the theme's trail colour, redrawn from the capture's
/// resampled polyline (at most `SwipeCaptureParameters.maxTrailPoints` points) and faded on lift.
///
/// Cost: a single layer and one path rebuild per touch-move; nothing is allocated per key. With Reduce Motion the
/// trail is still drawn while the finger is down (it is the direct echo of the finger) but disappears at once on
/// lift instead of fading. After a fade the layer stays invisible (opacity 0, a path of at most 120 points) until
/// the next swipe or `clear()`; it is touched from the main thread only.
public final class SwipeTrailLayer: CAShapeLayer {
    public static let fadeKey = "iboard.trailFade"

    public var trailStyle = SwipeTrailStyle(color: ThemeColor(hex: 0x007AFF)) {
        didSet { applyStyle() }
    }

    public override init() {
        super.init()
        fillColor = nil
        lineCap = .round
        lineJoin = .round
        zPosition = 1000 // above every key layer
        actions = ["path": NSNull(), "opacity": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "hidden": NSNull()]
        isHidden = true
        applyStyle()
    }

    public override init(layer: Any) { super.init(layer: layer) }
    public required init?(coder: NSCoder) { fatalError("unused") }

    private func applyStyle() {
        strokeColor = trailStyle.color.cgColor
        lineWidth = CGFloat(trailStyle.width)
    }

    /// Redraw from the polyline: a straight segment for two points, otherwise quadratic curves through midpoints.
    @MainActor
    public func update(points: [CGPoint]) {
        guard points.count > 1 else { return }
        removeAnimation(forKey: Self.fadeKey)
        let path = CGMutablePath()
        path.move(to: points[0])
        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            for i in 1..<points.count - 1 {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
            path.addLine(to: points[points.count - 1])
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.path = path
        opacity = 1
        isHidden = false
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
        path = nil
        isHidden = true
        opacity = 1
        CATransaction.commit()
    }
}
#endif
