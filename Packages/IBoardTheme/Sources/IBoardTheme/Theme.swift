import Foundation

// Theme model v1 (ROADMAP F10). Pure values, no UIKit; encoded as the `.iboardtheme` JSON file.

extension ThemeColor: Codable {
    /// Encoded as "#RRGGBB" or "#RRGGBBAA".
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = ThemeColor(hexString: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad colour"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hexString)
    }

    public init?(hexString: String) {
        guard hexString.hasPrefix("#"), hexString.utf8.count == 7 || hexString.utf8.count == 9,
              let v = UInt64(hexString.dropFirst(), radix: 16) else { return nil }
        if hexString.utf8.count == 7 {
            self.init(hex: UInt32(v))
        } else {
            self.init(hex: UInt32(v >> 8), alpha: Double(v & 0xFF) / 255)
        }
    }

    public var hexString: String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", c(red), c(green), c(blue))
        return alpha >= 1 ? rgb : rgb + String(format: "%02X", c(alpha))
    }

    /// WCAG relative luminance (alpha ignored).
    public var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrast(with other: ThemeColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public func withAlpha(_ a: Double) -> ThemeColor { ThemeColor(red: red, green: green, blue: blue, alpha: a) }
}

public enum BackdropKind: String, Sendable, Codable, CaseIterable {
    /// System keyboard glass drawn by iOS (P-22); the theme draws nothing behind the keys.
    case systemMaterial
    /// Pre-downsampled photo (referenced by `photoAsset`) with one blur + dim for the whole keyboard.
    case photo
    case gradient
    case solid
}

public struct Backdrop: Sendable, Codable, Equatable {
    public var kind: BackdropKind
    /// App Group asset name of the pre-sized photo (never a path, never embedded in the theme file).
    public var photoAsset: String?
    /// Photo blur radius in points, 0...40. One blur for the whole keyboard, never per key.
    public var blurRadius: Double
    /// Gradient stops (2...8) and angle in degrees, 0...360.
    public var gradient: [ThemeColor]
    public var gradientAngle: Double
    public var solid: ThemeColor

    public init(kind: BackdropKind, photoAsset: String? = nil, blurRadius: Double = 0, gradient: [ThemeColor] = [],
                gradientAngle: Double = 90, solid: ThemeColor = ThemeColor(hex: 0x000000, alpha: 0)) {
        self.kind = kind; self.photoAsset = photoAsset; self.blurRadius = blurRadius
        self.gradient = gradient; self.gradientAngle = gradientAngle; self.solid = solid
    }

    public static let system = Backdrop(kind: .systemMaterial)
}

public enum FontWeightToken: String, Sendable, Codable, CaseIterable {
    case regular, medium, semibold, bold
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    /// One step heavier, capped at bold (Bold Text).
    public var bolder: FontWeightToken { Self.allCases[min(rank + 1, Self.allCases.count - 1)] }
}

public struct FontSpec: Sendable, Codable, Equatable {
    /// nil = SF Pro (system font, default). Otherwise a PostScript/family name installed on the device.
    public var family: String?
    public var weight: FontWeightToken
    public var letterSize: Double
    public var uppercaseLetterSize: Double
    public var symbolSize: Double
    public var functionLabelSize: Double
    public init(family: String? = nil, weight: FontWeightToken = .regular, letterSize: Double, uppercaseLetterSize: Double,
                symbolSize: Double, functionLabelSize: Double) {
        self.family = family; self.weight = weight; self.letterSize = letterSize
        self.uppercaseLetterSize = uppercaseLetterSize; self.symbolSize = symbolSize; self.functionLabelSize = functionLabelSize
    }
}

public struct KeyStyle: Sendable, Codable, Equatable {
    public var fill: ThemeColor
    public var pressedFill: ThemeColor
    /// Multiplies fill alpha, 0...1.
    public var opacity: Double
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: ThemeColor
    public var shadowColor: ThemeColor
    public var shadowRadius: Double
    public var shadowOffsetY: Double
    public var actionFill: ThemeColor
    public var actionPressedFill: ThemeColor
    public init(fill: ThemeColor, pressedFill: ThemeColor, opacity: Double = 1, cornerRadius: Double,
                borderWidth: Double = 0, borderColor: ThemeColor = ThemeColor(hex: 0, alpha: 0),
                shadowColor: ThemeColor = ThemeColor(hex: 0, alpha: 0), shadowRadius: Double = 0, shadowOffsetY: Double = 0,
                actionFill: ThemeColor, actionPressedFill: ThemeColor) {
        self.fill = fill; self.pressedFill = pressedFill; self.opacity = opacity; self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth; self.borderColor = borderColor; self.shadowColor = shadowColor
        self.shadowRadius = shadowRadius; self.shadowOffsetY = shadowOffsetY
        self.actionFill = actionFill; self.actionPressedFill = actionPressedFill
    }
}

public struct LabelColors: Sendable, Codable, Equatable {
    public var key: ThemeColor
    public var actionKey: ThemeColor
    public var strip: ThemeColor
    public var stripSecondary: ThemeColor
    public init(key: ThemeColor, actionKey: ThemeColor, strip: ThemeColor, stripSecondary: ThemeColor) {
        self.key = key; self.actionKey = actionKey; self.strip = strip; self.stripSecondary = stripSecondary
    }
}

public struct SwipeTrailStyle: Sendable, Codable, Equatable {
    public var color: ThemeColor
    public var width: Double
    /// Seconds the trail takes to fade, 0.05...2.
    public var fadeDuration: Double
    public init(color: ThemeColor, width: Double = 4, fadeDuration: Double = 0.4) {
        self.color = color; self.width = width; self.fadeDuration = fadeDuration
    }
}

public enum StripStyleKind: String, Sendable, Codable, CaseIterable {
    /// Transparent over the backdrop with hairline separators (native look).
    case plain
    /// Suggestions in rounded chips.
    case chips
    /// Opaque bar.
    case filled
}

public struct StripStyle: Sendable, Codable, Equatable {
    public var kind: StripStyleKind
    public var background: ThemeColor
    public var separator: ThemeColor
    public init(kind: StripStyleKind, background: ThemeColor = ThemeColor(hex: 0, alpha: 0), separator: ThemeColor) {
        self.kind = kind; self.background = background; self.separator = separator
    }
}

/// One appearance (light or dark) of a theme.
public struct ThemeVariant: Sendable, Codable, Equatable {
    public var backdrop: Backdrop
    /// Black overlay over photo/gradient backdrops, 0...0.8.
    public var dim: Double
    /// Backdrop translucency 0 (opaque) ... 1. Only meaningful for non-system backdrops.
    public var translucency: Double
    public var keys: KeyStyle
    public var fonts: FontSpec
    public var labels: LabelColors
    public var swipeTrail: SwipeTrailStyle
    public var strip: StripStyle
    public init(backdrop: Backdrop, dim: Double = 0, translucency: Double = 1, keys: KeyStyle, fonts: FontSpec,
                labels: LabelColors, swipeTrail: SwipeTrailStyle, strip: StripStyle) {
        self.backdrop = backdrop; self.dim = dim; self.translucency = translucency; self.keys = keys
        self.fonts = fonts; self.labels = labels; self.swipeTrail = swipeTrail; self.strip = strip
    }
}

public struct Theme: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    /// Stable identifier; presets use "native", "nativeGlass", ...; user themes use a UUID string.
    public var id: String
    public var name: String
    public var light: ThemeVariant
    public var dark: ThemeVariant

    public init(schemaVersion: Int = Theme.currentSchemaVersion, id: String, name: String, light: ThemeVariant, dark: ThemeVariant) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name; self.light = light; self.dark = dark
    }

    public func variant(for appearance: ThemeAppearance) -> ThemeVariant {
        appearance == .light ? light : dark
    }
}
