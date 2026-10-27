import Foundation
import Testing
@testable import IBoardTheme

@Test func nativePresetIsTokenIdentical() {
    for a in ThemeAppearance.allCases {
        // Identical to the measured tokens except that the key tile is slightly translucent (ThemePresets.nativeKeyAlpha).
        var t = NativeThemeTokens.tokens(for: a)
        t.keyFill = t.keyFill.withAlpha(a == .light ? ThemePresets.nativeKeyAlpha.light : ThemePresets.nativeKeyAlpha.dark)
        var back = ThemePresets.native.variant(for: a).nativeTokens
        back.appearance = a
        #expect(back == t)
        #expect(ThemePresets.native.variant(for: a).backdrop.kind == .systemMaterial)
    }
}

@Test func nativeGlassKeepsSystemBackdrop() {
    for a in ThemeAppearance.allCases {
        let v = ThemePresets.nativeGlass.variant(for: a)
        #expect(v.backdrop == .system)
        #expect(v.dim == 0)
        #expect(v.keys.fill.alpha < 1)
        #expect(v.keys.fill.hex == NativeThemeTokens.tokens(for: a).keyFill.hex)
    }
}

@Test func allPresetsValidateAndRoundTrip() throws {
    #expect(ThemePresets.all.count == 5)
    for t in ThemePresets.all {
        let data = try ThemeFile.export(t)
        #expect(data.count < ThemeFile.maxBytes)
        let back = try ThemeFile.import(data)
        #expect(back.id == t.id && back.name == t.name)
        // Colours round-trip through 8-bit hex; the second export must be byte-identical.
        #expect(try ThemeFile.export(back) == data)
        #expect(ThemePresets.preset(id: t.id) == t)
    }
}

@Test func highContrastMeetsAAA() {
    for a in ThemeAppearance.allCases {
        let v = ThemePresets.highContrast.variant(for: a)
        #expect(v.labels.key.contrast(with: v.keys.fill) >= 7)
        #expect(v.labels.actionKey.contrast(with: v.keys.actionFill) >= 7)
    }
}

@Test func reduceTransparencyIsOpaque() {
    for t in ThemePresets.all {
        for a in ThemeAppearance.allCases {
            let r = t.resolved(.init(reduceTransparency: true), appearance: a)
            #expect(r.backdrop.kind == .solid && r.backdrop.solid.alpha == 1)
            #expect(r.keys.fill.alpha == 1 && r.dim == 0 && r.translucency == 1)
        }
    }
    #expect(ThemePresets.native.resolved(.none, appearance: .light) == ThemePresets.native.light)
}

@Test func increaseContrastAndBold() {
    let a = ThemeAccessibilitySettings(increaseContrast: true, boldText: true)
    for t in ThemePresets.all {
        for ap in ThemeAppearance.allCases {
            let base = t.variant(for: ap)
            let r = t.resolved(a, appearance: ap)
            #expect(r.keys.borderWidth >= 1)
            let before = base.labels.key.contrast(with: base.keys.fill)
            let after = r.labels.key.contrast(with: r.keys.fill)
            #expect(after >= 7 || after >= before)
            #expect(r.fonts.weight.rank >= base.fonts.weight.rank)
        }
    }
    #expect(ThemePresets.native.resolved(.init(boldText: true), appearance: .light).fonts.weight == .medium)
    #expect(FontWeightToken.bold.bolder == .bold)
}

@Test func importRejectsBadInput() throws {
    #expect(throws: ThemeError.malformed) { try ThemeFile.import(Data("nope".utf8)) }
    #expect(throws: ThemeError.tooLarge(bytes: ThemeFile.maxBytes + 1)) {
        try ThemeFile.import(Data(count: ThemeFile.maxBytes + 1))
    }
    var json = try #require(try JSONSerialization.jsonObject(with: ThemeFile.export(ThemePresets.paper)) as? [String: Any])
    json["schemaVersion"] = 99
    #expect(throws: ThemeError.unsupportedVersion(99)) {
        try ThemeFile.import(JSONSerialization.data(withJSONObject: json))
    }

    var t = ThemePresets.paper
    t.light.dim = 5
    #expect(throws: ThemeError.invalid("light.dim")) { try ThemeFile.validate(t) }
    t = ThemePresets.paper
    t.dark.backdrop = Backdrop(kind: .photo, photoAsset: "../../etc/passwd")
    #expect(throws: ThemeError.invalid("dark.backdrop.photoAsset")) { try ThemeFile.validate(t) }
    t = ThemePresets.paper
    t.light.backdrop = Backdrop(kind: .gradient, gradient: [ThemeColor(hex: 0)])
    #expect(throws: ThemeError.invalid("light.backdrop.gradient")) { try ThemeFile.validate(t) }
    t = ThemePresets.paper
    t.name = String(repeating: "x", count: 200)
    #expect(throws: ThemeError.invalid("name")) { try ThemeFile.validate(t) }
    t = ThemePresets.paper
    t.light.keys.cornerRadius = .nan
    #expect(throws: ThemeError.invalid("light.keys.cornerRadius")) { try ThemeFile.validate(t) }
}

@Test func badColourStringIsMalformed() throws {
    var s = String(decoding: try ThemeFile.export(ThemePresets.paper), as: UTF8.self)
    s = s.replacingOccurrences(of: "#EFE8D8", with: "red")
    #expect(throws: ThemeError.malformed) { try ThemeFile.import(Data(s.utf8)) }
}

@Test func colourHexStrings() {
    #expect(ThemeColor(hexString: "#007AFF")?.hex == 0x007AFF)
    #expect((ThemeColor(hexString: "#00000080")?.alpha ?? 0) > 0.49)
    #expect(ThemeColor(hexString: "007AFF") == nil)
    #expect(ThemeColor(hex: 0x123456, alpha: 0.5).hexString == "#12345680")
}
