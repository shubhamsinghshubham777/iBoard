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
#endif
