import Foundation

extension ThemeVariant {
    /// Native variant built from `NativeThemeTokens`, so the two can never drift.
    public init(native t: NativeThemeTokens, keyFillAlpha: Double = 1, strip: StripStyle? = nil) {
        let separator = t.appearance == .light ? ThemeColor(hex: 0x000000, alpha: 0.15) : ThemeColor(hex: 0xFFFFFF, alpha: 0.2)
        self.init(
            backdrop: .system,
            keys: KeyStyle(fill: t.keyFill.withAlpha(keyFillAlpha), pressedFill: t.keyPressedFill, cornerRadius: 8.47,
                           actionFill: t.actionKeyFill, actionPressedFill: t.actionKeyPressedFill),
            fonts: FontSpec(letterSize: t.letterFontSize, uppercaseLetterSize: t.uppercaseLetterFontSize,
                            symbolSize: t.symbolFontSize, functionLabelSize: t.functionLabelFontSize),
            labels: LabelColors(key: t.keyLabel, actionKey: t.actionKeyLabel, strip: t.keyLabel,
                                stripSecondary: t.keyLabel.withAlpha(0.6)),
            // Neutral ink from the label colour: the system-blue accent looked out of place on grey keys.
            swipeTrail: SwipeTrailStyle(color: t.keyLabel.withAlpha(0.8)),
            strip: strip ?? StripStyle(kind: .plain, separator: separator)
        )
    }

    /// Native key colours as the existing token struct (for IBoardUI during migration). Appearance is not stored in a
    /// variant; the caller sets it.
    public var nativeTokens: NativeThemeTokens {
        var t = NativeThemeTokens.light
        t.keyFill = keys.fill; t.keyPressedFill = keys.pressedFill; t.keyLabel = labels.key
        t.actionKeyFill = keys.actionFill; t.actionKeyPressedFill = keys.actionPressedFill; t.actionKeyLabel = labels.actionKey
        t.letterFontSize = fonts.letterSize; t.uppercaseLetterFontSize = fonts.uppercaseLetterSize
        t.symbolFontSize = fonts.symbolSize; t.functionLabelFontSize = fonts.functionLabelSize
        return t
    }
}

public enum ThemePresets {
    /// Native: token-identical to `NativeThemeTokens`; system backdrop (P-22).
    public static let native = Theme(id: "native", name: "Native",
                                     light: ThemeVariant(native: .light, keyFillAlpha: nativeKeyAlpha.light),
                                     dark: ThemeVariant(native: .dark, keyFillAlpha: nativeKeyAlpha.dark))

    /// The system keyboard's tiles let the glass backdrop show through a little (owner request 2026-10-27, from a
    /// screenshot of the Apple keyboard); the colours stay the measured ones. Reduce Transparency makes them opaque.
    public static let nativeKeyAlpha = (light: 0.62, dark: 0.5)

    /// Native Glass: still the system backdrop (P-22: no full-sheet effect). Only key fill/tint varies: translucent
    /// tiles with a hairline edge so the glass shows through.
    public static let nativeGlass: Theme = {
        func glass(_ t: NativeThemeTokens, alpha: Double, edge: ThemeColor) -> ThemeVariant {
            var v = ThemeVariant(native: t, keyFillAlpha: alpha)
            v.keys.pressedFill = t.keyPressedFill.withAlpha(min(alpha + 0.2, 1))
            v.keys.borderWidth = 0.5
            v.keys.borderColor = edge
            return v
        }
        return Theme(id: "nativeGlass", name: "Native Glass",
                     light: glass(.light, alpha: 0.55, edge: ThemeColor(hex: 0xFFFFFF, alpha: 0.7)),
                     dark: glass(.dark, alpha: 0.4, edge: ThemeColor(hex: 0xFFFFFF, alpha: 0.18)))
    }()

    private static func solidVariant(bg: UInt32, key: UInt32, pressed: UInt32, label: UInt32, action: UInt32,
                                     actionPressed: UInt32, actionLabel: UInt32, radius: Double, border: ThemeColor? = nil,
                                     borderWidth: Double = 0, shadow: Bool, trail: UInt32, separator: ThemeColor,
                                     weight: FontWeightToken = .regular) -> ThemeVariant {
        ThemeVariant(
            backdrop: Backdrop(kind: .solid, solid: ThemeColor(hex: bg)),
            keys: KeyStyle(fill: ThemeColor(hex: key), pressedFill: ThemeColor(hex: pressed), cornerRadius: radius,
                           borderWidth: borderWidth, borderColor: border ?? ThemeColor(hex: 0, alpha: 0),
                           shadowColor: shadow ? ThemeColor(hex: 0, alpha: 0.35) : ThemeColor(hex: 0, alpha: 0),
                           shadowRadius: shadow ? 0.5 : 0, shadowOffsetY: shadow ? 1 : 0,
                           actionFill: ThemeColor(hex: action), actionPressedFill: ThemeColor(hex: actionPressed)),
            fonts: FontSpec(weight: weight, letterSize: 25, uppercaseLetterSize: 22, symbolSize: 25, functionLabelSize: 16),
            labels: LabelColors(key: ThemeColor(hex: label), actionKey: ThemeColor(hex: actionLabel),
                                strip: ThemeColor(hex: label), stripSecondary: ThemeColor(hex: label, alpha: 0.6)),
            swipeTrail: SwipeTrailStyle(color: ThemeColor(hex: trail)),
            strip: StripStyle(kind: .plain, separator: separator)
        )
    }

    public static let midnight = Theme(
        id: "midnight", name: "Midnight",
        light: solidVariant(bg: 0xE6E8F2, key: 0xFFFFFF, pressed: 0xC5C9DC, label: 0x14172B, action: 0x4B5BD6,
                            actionPressed: 0x3B49B0, actionLabel: 0xFFFFFF, radius: 8.47, shadow: true, trail: 0x4B5BD6,
                            separator: ThemeColor(hex: 0x14172B, alpha: 0.15)),
        dark: solidVariant(bg: 0x0B0D1A, key: 0x1C2038, pressed: 0x2E3560, label: 0xE8EAFF, action: 0x6C7BFF,
                           actionPressed: 0x5362E0, actionLabel: 0x0B0D1A, radius: 8.47, shadow: false, trail: 0x8E9AFF,
                           separator: ThemeColor(hex: 0xE8EAFF, alpha: 0.18)))

    public static let paper: Theme = {
        let v = solidVariant(bg: 0xEFE8D8, key: 0xFBF7EC, pressed: 0xDDD3BC, label: 0x2B2418, action: 0x8A5A2B,
                             actionPressed: 0x6F4620, actionLabel: 0xFFFFFF, radius: 6, border: ThemeColor(hex: 0xCFC4A8),
                             borderWidth: 0.5, shadow: true, trail: 0x8A5A2B, separator: ThemeColor(hex: 0x2B2418, alpha: 0.15))
        let d = solidVariant(bg: 0x2A2620, key: 0x3A352C, pressed: 0x544C3E, label: 0xF0E8D6, action: 0xC99A5B,
                             actionPressed: 0xA97F47, actionLabel: 0x2A2620, radius: 6, border: ThemeColor(hex: 0x4A4437),
                             borderWidth: 0.5, shadow: false, trail: 0xC99A5B, separator: ThemeColor(hex: 0xF0E8D6, alpha: 0.18))
        return Theme(id: "paper", name: "Paper", light: v, dark: d)
    }()

    /// High Contrast: WCAG AAA (>= 7:1) label/fill pairs, 1 pt borders, bold labels.
    public static let highContrast = Theme(
        id: "highContrast", name: "High Contrast",
        light: solidVariant(bg: 0xFFFFFF, key: 0xFFFFFF, pressed: 0xD0D0D0, label: 0x000000, action: 0x0040DD,
                            actionPressed: 0x002C9C, actionLabel: 0xFFFFFF, radius: 8.47, border: ThemeColor(hex: 0x000000),
                            borderWidth: 1, shadow: false, trail: 0x0040DD, separator: ThemeColor(hex: 0x000000),
                            weight: .bold),
        dark: solidVariant(bg: 0x000000, key: 0x000000, pressed: 0x3A3A3A, label: 0xFFFFFF, action: 0xFFD60A,
                           actionPressed: 0xCCAB08, actionLabel: 0x000000, radius: 8.47, border: ThemeColor(hex: 0xFFFFFF),
                           borderWidth: 1, shadow: false, trail: 0xFFD60A, separator: ThemeColor(hex: 0xFFFFFF),
                           weight: .bold))

    public static let all: [Theme] = [native, nativeGlass, midnight, paper, highContrast]

    public static func preset(id: String) -> Theme? { all.first { $0.id == id } }
}
