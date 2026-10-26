/// sRGB colour as plain values (no UIKit), so tokens are testable on macOS.
public struct ThemeColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// `0xRRGGBB` of the colour (alpha ignored); used by tests and debugging.
    public var hex: UInt32 {
        func c(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return (c(red) << 16) | (c(green) << 8) | c(blue)
    }
}

public enum ThemeAppearance: String, Sendable, CaseIterable {
    case light, dark
}

/// Native theme tokens for the key grid (M1-03): the iOS 27.0 system keyboard as measured by M1-01
/// (`docs/reference/native-metrics.json`, iPhone 12 simulator, translucent fills sampled over a white host).
///
/// There is deliberately no backdrop token: per P-22 the system draws the keyboard backdrop (glass) behind the
/// extension and a custom backdrop effect looks wrong, so Native only varies the key tiles.
public struct NativeThemeTokens: Sendable, Equatable {
    public var appearance: ThemeAppearance

    /// Fill of every key tile (letters and function keys are not distinguished in iOS 27.0, measured).
    public var keyFill: ThemeColor
    /// Fill while a key is held. ESTIMATED (pressed colour not captured by M1-01); tune against the system keyboard.
    public var keyPressedFill: ThemeColor
    public var keyLabel: ThemeColor
    /// Blue action return key (go / search / send / done / ...): `#007AFF` with a white glyph in both appearances.
    public var actionKeyFill: ThemeColor
    public var actionKeyPressedFill: ThemeColor
    public var actionKeyLabel: ThemeColor

    /// Font sizes in points (letters derived from measured x-height / cap-height, so ESTIMATED to about 1 pt).
    public var letterFontSize: Double
    public var uppercaseLetterFontSize: Double
    public var symbolFontSize: Double
    public var functionLabelFontSize: Double

    public static func tokens(for appearance: ThemeAppearance) -> NativeThemeTokens {
        switch appearance {
        case .light: .light
        case .dark: .dark
        }
    }

    public static let light = NativeThemeTokens(
        appearance: .light,
        keyFill: ThemeColor(hex: 0xFFFFFF),
        keyPressedFill: ThemeColor(hex: 0xC8CAD0),
        keyLabel: ThemeColor(hex: 0x000000),
        actionKeyFill: ThemeColor(hex: 0x007AFF),
        actionKeyPressedFill: ThemeColor(hex: 0x0062CC),
        actionKeyLabel: ThemeColor(hex: 0xFFFFFF),
        letterFontSize: 25, uppercaseLetterFontSize: 22, symbolFontSize: 25, functionLabelFontSize: 16
    )

    public static let dark = NativeThemeTokens(
        appearance: .dark,
        keyFill: ThemeColor(hex: 0x575757),
        keyPressedFill: ThemeColor(hex: 0x7E7E7E),
        keyLabel: ThemeColor(hex: 0xFFFFFF),
        actionKeyFill: ThemeColor(hex: 0x007AFF),
        actionKeyPressedFill: ThemeColor(hex: 0x0062CC),
        actionKeyLabel: ThemeColor(hex: 0xFFFFFF),
        letterFontSize: 25, uppercaseLetterFontSize: 22, symbolFontSize: 25, functionLabelFontSize: 16
    )
}
