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
