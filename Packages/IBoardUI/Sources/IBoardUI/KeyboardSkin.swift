import CoreGraphics
import Foundation
import IBoardTheme

// What the keyboard draws, resolved from a `Theme` (F10, M8-01). UIKit-free so it is testable on macOS. The key grid,
// glyph cache, strip and backdrop view read only this; the Native preset resolves to exactly `NativeThemeTokens`
// (`KeyboardSkinTests.nativeSkinIsTokenIdentical`), so the default look is unchanged.

/// What sits behind the keys. `system` draws nothing: iOS paints the keyboard glass (P-22).
public struct BackdropSpec: Equatable, Sendable {
    public var kind: BackdropKind
    /// Safe photo token (file name stem written by the app), only for `.photo`.
    public var photoToken: String?
    public var blurRadius: Double
    public var gradient: [ThemeColor]
    /// Degrees; 90 = top to bottom, 0 = left to right (the companion app preview uses the same convention).
    public var gradientAngle: Double
    public var solid: ThemeColor
    /// Black overlay over photo / gradient, 0...0.8.
    public var dim: Double
    /// Whole-backdrop opacity. The companion app previews a backdrop at `translucency * 0.5 + 0.5` (so 1 is fully
    /// opaque, which is also what Reduce Transparency sets); the same rule is used here.
    public var opacity: Double

    public static let system = BackdropSpec(kind: .systemMaterial, photoToken: nil, blurRadius: 0, gradient: [],
                                            gradientAngle: 90, solid: ThemeColor(hex: 0, alpha: 0), dim: 0, opacity: 1)

    public var drawsAnything: Bool { kind != .systemMaterial }

    /// Unit-square start / end points of a CAGradientLayer for `gradientAngle` (direction = (cos a, sin a), y down).
    public var gradientPoints: (start: CGPoint, end: CGPoint) {
        let a = gradientAngle * .pi / 180
        let dx = cos(a) / 2, dy = sin(a) / 2
        return (CGPoint(x: 0.5 - dx, y: 0.5 - dy), CGPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

public struct KeyboardSkin: Equatable, Sendable {
    public var appearance: ThemeAppearance
    /// Key / label colours and font sizes in the shape the renderer already used (fills carry the theme's opacity).
    public var tokens: NativeThemeTokens
    /// Theme corner radius relative to the native 8.47 pt; multiplied onto the layout's own (size-scaled) radius, so
    /// Native is exactly the layout radius.
    public var cornerRadiusScale: Double
    public var fontWeight: FontWeightToken
    /// nil = SF Pro.
    public var fontFamily: String?
    public var keyBorderWidth: Double
    public var keyBorderColor: ThemeColor
    public var keyShadowColor: ThemeColor
    public var keyShadowRadius: Double
    public var keyShadowOffsetY: Double
    public var trail: SwipeTrailStyle
    public var stripLabel: ThemeColor
    public var stripSeparator: ThemeColor
    public var stripKind: StripStyleKind
    public var stripBackground: ThemeColor
    public var backdrop: BackdropSpec

    static let nativeCornerRadius = 8.47

    /// The Native skin for an appearance (no accessibility settings).
    public static func native(_ appearance: ThemeAppearance) -> KeyboardSkin {
        KeyboardSkin(theme: ThemePresets.native, appearance: appearance, accessibility: .none)
    }

    /// Resolves `theme` for `appearance` under the system accessibility switches (Reduce Transparency, Increase
    /// Contrast, Bold Text) via `ThemeVariant.resolved`.
    public init(theme: Theme, appearance: ThemeAppearance, accessibility: ThemeAccessibilitySettings) {
        let v = theme.resolved(accessibility, appearance: appearance)
        var t = v.nativeTokens
        t.appearance = appearance
        if v.keys.opacity < 1 {
            t.keyFill = t.keyFill.withAlpha(t.keyFill.alpha * v.keys.opacity)
            t.keyPressedFill = t.keyPressedFill.withAlpha(t.keyPressedFill.alpha * v.keys.opacity)
        }
        self.appearance = appearance
        self.tokens = t
        self.cornerRadiusScale = v.keys.cornerRadius / Self.nativeCornerRadius
        self.fontWeight = v.fonts.weight
        self.fontFamily = v.fonts.family
        self.keyBorderWidth = v.keys.borderWidth
        self.keyBorderColor = v.keys.borderColor
        self.keyShadowColor = v.keys.shadowColor
        self.keyShadowRadius = v.keys.shadowRadius
        self.keyShadowOffsetY = v.keys.shadowOffsetY
        self.trail = v.swipeTrail
        self.stripLabel = v.labels.strip
        // The shipped Native strip draws its dividers at 18 % of the label colour while the Native preset records
        // 15 % / 20 % black / white. Keep the shipped look for the unmodified default separator (pixel-identical
        // Native); any other separator (themes, Increase Contrast) is drawn as the theme says.
        let nativeSeparator = ThemeVariant(native: NativeThemeTokens.tokens(for: appearance)).strip.separator
        self.stripSeparator = v.strip.separator == nativeSeparator ? v.labels.key.withAlpha(0.18) : v.strip.separator
        self.stripKind = v.strip.kind
        self.stripBackground = v.strip.background
        let b = v.backdrop
        self.backdrop = BackdropSpec(
            kind: b.kind, photoToken: b.kind == .photo ? b.photoAsset : nil, blurRadius: b.blurRadius,
            gradient: b.gradient, gradientAngle: b.gradientAngle, solid: b.solid, dim: v.dim,
            opacity: b.kind == .systemMaterial ? 1 : v.translucency * 0.5 + 0.5)
    }

    /// True when keys draw a border or shadow (the Native key is a plain tile).
    public var keysNeedDecoration: Bool { keyBorderWidth > 0 || (keyShadowColor.alpha > 0 && keyShadowRadius > 0) }
}
