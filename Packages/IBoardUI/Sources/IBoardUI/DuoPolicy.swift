import CoreGraphics
import Foundation
import IBoardLayout

// iPhone Duo host rules (D-20, F12, F18). Pure and UIKit-free; no device model is ever consulted (P-14: extensions
// get no hinge data), only display metrics the extension can read from its screen. Nothing here sees typed text.

public enum DisplayMetrics {
    /// Shortest screen side (points) from which a display counts as the Duo OUTER display. Outer is 466 x 678 pt
    /// (P-13); the widest iPhone is 440 pt (Pro Max class), so 450 separates them with a 10 pt margin. ESTIMATED
    /// rule: a future phone with a wider short side would be misread as a Duo.
    public static let outerMinShortSide: CGFloat = 450
    /// Shortest side from which a display is the Duo INNER display (669 x 951 pt, P-13).
    public static let innerMinShortSide: CGFloat = 600

    /// `screenSize` is the screen's bounds in its current orientation (width < height in portrait).
    public static func displayClass(screenSize: CGSize) -> DisplayClass {
        let short = min(screenSize.width, screenSize.height)
        guard short.isFinite, short > 0 else { return .phone }
        if short >= innerMinShortSide { return .duoInner }
        if short >= outerMinShortSide { return .duoOuter }
        return .phone
    }

    /// Orientation from the screen shape (the screen bounds rotate with the interface).
    public static func orientation(screenSize: CGSize) -> LayoutOrientation {
        screenSize.width > screenSize.height ? .landscape : .portrait
    }
}

/// Split choice per orientation (F12): the user's pinch (extension-local, the extension cannot write the App Group
/// without Full Access, P-23) wins, then an explicit value the app saved, then the layout default (D-20: split in
/// inner landscape).
public enum DuoSplitPolicy {
    public static func resolve(local: Bool?, app: Bool?, fallback: Bool) -> Bool { local ?? app ?? fallback }

    /// The value the app explicitly stored under `key` in the raw settings blob; nil when there is no blob or the key
    /// is absent. `IBoardSettings` decoding cannot tell "default" from "saved false", so the raw JSON is checked.
    public static func explicitAppValue(blob: Data?, key: String) -> Bool? {
        guard let blob, let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] else { return nil }
        return obj[key] as? Bool
    }

    /// Pinch outcome: spread (scale > 1.15) splits, pinch together (< 0.87) merges (as the iPad keyboard does);
    /// anything in between is no decision.
    public static func decision(forPinchScale scale: CGFloat) -> Bool? {
        if scale > 1.15 { return true }
        if scale < 0.87 { return false }
        return nil
    }
}

/// Extension-local memory of the pinch and the laptop fill-to-fold snap. Plain `UserDefaults` of the extension
/// container. Contains no typed text.
public struct DuoLocalStore: @unchecked Sendable {
    public static let splitPrefix = "iboard.local.duoSplit."
    public static let fillKey = "iboard.local.duoFillToFold"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func split(for orientation: LayoutOrientation) -> Bool? {
        let k = Self.splitPrefix + orientation.rawValue
        return defaults.object(forKey: k) == nil ? nil : defaults.bool(forKey: k)
    }

    public func setSplit(_ on: Bool, for orientation: LayoutOrientation) {
        defaults.set(on, forKey: Self.splitPrefix + orientation.rawValue)
    }

    public var fillToFold: Bool { defaults.bool(forKey: Self.fillKey) }
    public func setFillToFold(_ on: Bool) { defaults.set(on, forKey: Self.fillKey) }
}
