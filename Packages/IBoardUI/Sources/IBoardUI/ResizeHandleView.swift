import CoreGraphics

/// Pure resize math (F11): the keyboard height is linear in the height scale, so a drag maps to a scale by
/// interpolating between the heights at scale 0 and 1. UIKit-free for tests.
public enum ResizeMath {
    /// Scale for a target height, clamped to `lower...upper`. `height0` / `height1` are `preferredHeight` at scale
    /// 0 and 1.
    public static func scale(forHeight h: CGFloat, height0: CGFloat, height1: CGFloat,
                             lower: Double = 0.8, upper: Double = 1.4) -> Double {
        let span = height1 - height0
        guard span > 0 else { return 1 }
        let s = Double((h - height0) / span)
        return min(max(s, lower), upper)
    }
}

extension ResizeMath {
    /// Where the keyboard's top edge would sit (y from the keyboard's current top, 0 = unchanged) for a target
    /// height. Positive when the target is shorter (the edge moves down into the current area), 0 when it is
    /// taller (a keyboard extension cannot draw above its own bounds, P-15, so growth is shown by the readout).
    public static func previewTopOffset(currentHeight: CGFloat, targetHeight: CGFloat) -> CGFloat {
        max(0, currentHeight - targetHeight)
    }

    /// Readout text for a height scale, e.g. "110%".
    public static func percentText(scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }
}

#if canImport(UIKit)
import UIKit

/// Small grabber at the top of the keyboard (F11, D-18): drag up/down to resize, double-tap for the number row.
/// Only this 80 x 20 pt area takes touches; the rest of the strip stays transparent to the key grid.
@MainActor
public final class ResizeHandleView: UIView {
    public var onDragBegan: (() -> Void)?
    /// Vertical translation in points since the drag began (negative = finger moved up = taller keyboard).
    public var onDragChanged: ((CGFloat) -> Void)?
    public var onDragEnded: (() -> Void)?
    public var onDoubleTap: (() -> Void)?

    public static let size = CGSize(width: 80, height: 20)
    private let grabber = CALayer()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        grabber.cornerRadius = 2
        grabber.backgroundColor = UIColor.label.withAlphaComponent(0.25).cgColor
        layer.addSublayer(grabber)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        addGestureRecognizer(pan)
        let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTap))
        dbl.numberOfTapsRequired = 2
        addGestureRecognizer(dbl)
        isAccessibilityElement = true
        accessibilityLabel = "Resize keyboard"
        accessibilityIdentifier = "resize-handle"
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        grabber.frame = CGRect(x: bounds.midX - 18, y: 4, width: 36, height: 4)
    }

    private var startY: CGFloat = 0

    /// The keyboard's window moves while the keyboard resizes, so track the finger in screen space.
    private func screenY(_ g: UIGestureRecognizer) -> CGFloat {
        guard let window else { return g.location(in: nil).y }
        return convert(g.location(in: self), to: window.screen.coordinateSpace).y
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            startY = screenY(g)
            onDragBegan?()
        case .changed: onDragChanged?(screenY(g) - startY)
        case .ended, .cancelled, .failed: onDragEnded?()
        default: break
        }
    }

    @objc private func doubleTap() { onDoubleTap?() }
}

/// Stable overlay shown while the resize handle is dragged (F11). The keyboard itself is NOT resized during the
/// drag (live resizing moved the handle under the finger and flickered); this view shows the target instead, and the
/// caller applies ONE height change on release. Never takes touches.
@MainActor
public final class ResizePreviewView: UIView {
    private let scrim = CALayer()
    private let dim = CALayer()
    private let edge = CAShapeLayer()
    private let track = CALayer()
    private let thumb = CALayer()
    private let readout = UILabel()
    private let hint = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.42).cgColor
        scrim.cornerRadius = 12
        layer.addSublayer(scrim)
        layer.addSublayer(dim)
        edge.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        edge.lineWidth = 2
        edge.lineDashPattern = [6, 4]
        edge.fillColor = nil
        layer.addSublayer(edge)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.35).cgColor
        track.cornerRadius = 2
        layer.addSublayer(track)
        thumb.backgroundColor = UIColor.white.cgColor
        thumb.cornerRadius = 9
        thumb.shadowOpacity = 0.3
        thumb.shadowRadius = 2
        thumb.shadowOffset = .zero
        layer.addSublayer(thumb)
        readout.font = .systemFont(ofSize: 30, weight: .semibold)
        readout.textColor = .white
        readout.textAlignment = .center
        addSubview(readout)
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = UIColor.white.withAlphaComponent(0.85)
        hint.textAlignment = .center
        addSubview(hint)
        accessibilityElementsHidden = true
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    /// `scale` in `lower...upper`; `snapped` is the Duo laptop-pose "fill to fold" snap.
    public func update(scale: Double, lower: Double, upper: Double, targetHeight: CGFloat, currentHeight: CGFloat, snapped: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let top = ResizeMath.previewTopOffset(currentHeight: currentHeight, targetHeight: targetHeight)
        scrim.frame = bounds
        dim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.35).cgColor
        let path = CGMutablePath()
        if top > 0 { path.move(to: CGPoint(x: 0, y: top)); path.addLine(to: CGPoint(x: bounds.width, y: top)) }
        edge.path = path
        let trackTop: CGFloat = 28, trackBottom = bounds.height - 16
        track.frame = CGRect(x: bounds.width - 24, y: trackTop, width: 4, height: max(0, trackBottom - trackTop))
        let t = CGFloat((scale - lower) / max(upper - lower, 0.001))
        thumb.frame = CGRect(x: bounds.width - 31, y: trackBottom - t * (trackBottom - trackTop) - 9, width: 18, height: 18)
        CATransaction.commit()
        readout.text = snapped ? "Fill to fold" : ResizeMath.percentText(scale: scale)
        hint.text = targetHeight > currentHeight + 1 ? "Taller on release" : (targetHeight < currentHeight - 1 ? "Shorter on release" : "Release to keep")
        let h = max(top, 0)
        readout.frame = CGRect(x: 0, y: h + (bounds.height - h) / 2 - 24, width: bounds.width, height: 36)
        hint.frame = CGRect(x: 0, y: readout.frame.maxY, width: bounds.width, height: 18)
    }

    public func show() {
        isHidden = false
        guard !UIAccessibility.isReduceMotionEnabled else { alpha = 1; return }
        alpha = 0
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
    }

    public func hide() { isHidden = true }
}
#endif
