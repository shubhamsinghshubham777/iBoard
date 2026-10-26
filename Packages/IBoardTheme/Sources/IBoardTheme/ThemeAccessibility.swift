import Foundation

/// System accessibility switches relevant to theming (M8-05).
public struct ThemeAccessibilitySettings: Sendable, Equatable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool
    public var boldText: Bool
    public init(reduceTransparency: Bool = false, increaseContrast: Bool = false, boldText: Bool = false) {
        self.reduceTransparency = reduceTransparency; self.increaseContrast = increaseContrast; self.boldText = boldText
    }
    public static let none = ThemeAccessibilitySettings()
}

extension ThemeVariant {
    /// Pure resolution of a variant under the accessibility settings. Never mutates the stored theme.
    ///
    /// - Reduce Transparency: backdrop becomes opaque solid (the solid colour, first gradient stop, or the native
    ///   keyboard grey for system/photo), dim 0, translucency 1 (fully opaque), key fill alpha 1.
    /// - Increase Contrast: labels snap to black/white if below 7:1 against the key fill (action labels against the
    ///   action fill); keys get at least a 1 pt border (label colour at 0.6 alpha if none); strip separator opaque.
    /// - Bold Text: font weight one step heavier (capped at bold).
    public func resolved(_ a: ThemeAccessibilitySettings, appearance: ThemeAppearance) -> ThemeVariant {
        var v = self
        if a.reduceTransparency {
            let fallback: ThemeColor
            switch backdrop.kind {
            case .solid: fallback = backdrop.solid.withAlpha(1)
            case .gradient: fallback = (backdrop.gradient.first ?? ThemeColor(hex: 0)).withAlpha(1)
            case .systemMaterial, .photo: fallback = appearance == .light ? ThemeColor(hex: 0xD1D3D9) : ThemeColor(hex: 0x2B2B2D)
            }
            v.backdrop = Backdrop(kind: .solid, solid: fallback)
            v.dim = 0
            v.translucency = 1
            v.keys.opacity = 1
            v.keys.fill = v.keys.fill.withAlpha(1)
            v.keys.pressedFill = v.keys.pressedFill.withAlpha(1)
            if v.strip.kind != .plain { v.strip.background = v.strip.background.withAlpha(1) }
        }
        if a.increaseContrast {
            func ensure(_ label: ThemeColor, on fill: ThemeColor) -> ThemeColor {
                if label.contrast(with: fill) >= 7 { return label }
                let black = ThemeColor(hex: 0x000000), white = ThemeColor(hex: 0xFFFFFF)
                return black.contrast(with: fill) >= white.contrast(with: fill) ? black : white
            }
            v.labels.key = ensure(v.labels.key, on: v.keys.fill)
            v.labels.actionKey = ensure(v.labels.actionKey, on: v.keys.actionFill)
            v.keys.borderWidth = max(v.keys.borderWidth, 1)
            if v.keys.borderColor.alpha < 0.6 { v.keys.borderColor = v.labels.key.withAlpha(0.6) }
            v.strip.separator = v.strip.separator.withAlpha(1)
        }
        if a.boldText { v.fonts.weight = v.fonts.weight.bolder }
        return v
    }
}

extension Theme {
    public func resolved(_ a: ThemeAccessibilitySettings, appearance: ThemeAppearance) -> ThemeVariant {
        variant(for: appearance).resolved(a, appearance: appearance)
    }
}
