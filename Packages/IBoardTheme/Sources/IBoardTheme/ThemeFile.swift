import Foundation

public enum ThemeError: Error, Equatable, Sendable {
    case tooLarge(bytes: Int)
    case malformed
    case unsupportedVersion(Int)
    case invalid(String)
}

/// `.iboardtheme` import/export. Photos are never embedded (only `photoAsset` names), hence the small cap.
public enum ThemeFile {
    public static let fileExtension = "iboardtheme"
    public static let maxBytes = 64 * 1024

    public static func export(_ theme: Theme) throws -> Data {
        try validate(theme)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(theme)
        guard data.count <= maxBytes else { throw ThemeError.tooLarge(bytes: data.count) }
        return data
    }

    public static func `import`(_ data: Data) throws -> Theme {
        guard data.count <= maxBytes else { throw ThemeError.tooLarge(bytes: data.count) }
        // Check the version before the full decode so newer files report a clear error.
        struct Probe: Decodable { var schemaVersion: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { throw ThemeError.malformed }
        guard probe.schemaVersion >= 1, probe.schemaVersion <= Theme.currentSchemaVersion else {
            throw ThemeError.unsupportedVersion(probe.schemaVersion)
        }
        guard let theme = try? JSONDecoder().decode(Theme.self, from: data) else { throw ThemeError.malformed }
        try validate(theme)
        return theme
    }

    public static func validate(_ t: Theme) throws {
        func bad(_ m: String) -> ThemeError { .invalid(m) }
        guard t.schemaVersion == Theme.currentSchemaVersion else { throw ThemeError.unsupportedVersion(t.schemaVersion) }
        guard !t.id.isEmpty, t.id.utf8.count <= 64 else { throw bad("id") }
        guard !t.name.isEmpty, t.name.utf8.count <= 80 else { throw bad("name") }
        for (label, v) in [("light", t.light), ("dark", t.dark)] {
            try validate(v, label)
        }
    }

    private static func validate(_ v: ThemeVariant, _ p: String) throws {
        func range(_ x: Double, _ lo: Double, _ hi: Double, _ n: String) throws {
            guard x.isFinite, x >= lo, x <= hi else { throw ThemeError.invalid("\(p).\(n)") }
        }
        func color(_ c: ThemeColor, _ n: String) throws {
            for x in [c.red, c.green, c.blue, c.alpha] { try range(x, 0, 1, n) }
        }
        let b = v.backdrop
        try range(b.blurRadius, 0, 40, "backdrop.blurRadius")
        try range(b.gradientAngle, 0, 360, "backdrop.gradientAngle")
        try color(b.solid, "backdrop.solid")
        try b.gradient.forEach { try color($0, "backdrop.gradient") }
        if b.kind == .gradient, !(2...8).contains(b.gradient.count) { throw ThemeError.invalid("\(p).backdrop.gradient") }
        if b.gradient.count > 8 { throw ThemeError.invalid("\(p).backdrop.gradient") }
        if b.kind == .photo {
            guard let a = b.photoAsset, isSafeAssetName(a) else { throw ThemeError.invalid("\(p).backdrop.photoAsset") }
        } else if let a = b.photoAsset, !isSafeAssetName(a) {
            throw ThemeError.invalid("\(p).backdrop.photoAsset")
        }
        try range(v.dim, 0, 0.8, "dim")
        try range(v.translucency, 0, 1, "translucency")
        let k = v.keys
        try range(k.opacity, 0, 1, "keys.opacity")
        try range(k.cornerRadius, 0, 30, "keys.cornerRadius")
        try range(k.borderWidth, 0, 4, "keys.borderWidth")
        try range(k.shadowRadius, 0, 12, "keys.shadowRadius")
        try range(k.shadowOffsetY, -12, 12, "keys.shadowOffsetY")
        for (n, c) in [("fill", k.fill), ("pressedFill", k.pressedFill), ("borderColor", k.borderColor),
                       ("shadowColor", k.shadowColor), ("actionFill", k.actionFill), ("actionPressedFill", k.actionPressedFill)] {
            try color(c, "keys.\(n)")
        }
        let f = v.fonts
        if let fam = f.family, fam.isEmpty || fam.utf8.count > 64 { throw ThemeError.invalid("\(p).fonts.family") }
        for (n, s) in [("letterSize", f.letterSize), ("uppercaseLetterSize", f.uppercaseLetterSize),
                       ("symbolSize", f.symbolSize), ("functionLabelSize", f.functionLabelSize)] {
            try range(s, 8, 48, "fonts.\(n)")
        }
        for (n, c) in [("key", v.labels.key), ("actionKey", v.labels.actionKey), ("strip", v.labels.strip),
                       ("stripSecondary", v.labels.stripSecondary)] { try color(c, "labels.\(n)") }
        try color(v.swipeTrail.color, "swipeTrail.color")
        try range(v.swipeTrail.width, 1, 16, "swipeTrail.width")
        try range(v.swipeTrail.fadeDuration, 0.05, 2, "swipeTrail.fadeDuration")
        try color(v.strip.background, "strip.background")
        try color(v.strip.separator, "strip.separator")
    }

    /// Asset names are plain file-name tokens: no separators, no leading dot, bounded length.
    static func isSafeAssetName(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 64, !s.hasPrefix(".") else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
}
