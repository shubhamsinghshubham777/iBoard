import Foundation
import Testing
import IBoardTheme
@testable import IBoardUI

@Suite("Keyboard skin")
struct KeyboardSkinTests {
    @Test func nativeSkinIsTokenIdentical() {
        for appearance in ThemeAppearance.allCases {
            let s = KeyboardSkin.native(appearance)
            var expected = NativeThemeTokens.tokens(for: appearance)
            expected.keyFill = expected.keyFill.withAlpha(appearance == .light ? ThemePresets.nativeKeyAlpha.light : ThemePresets.nativeKeyAlpha.dark)
            #expect(s.tokens == expected)
            #expect(s.cornerRadiusScale == 1)
            #expect(s.fontWeight == .regular)
            #expect(s.fontFamily == nil)
            #expect(!s.keysNeedDecoration)
            #expect(s.backdrop == .system)
            #expect(!s.backdrop.drawsAnything)
            #expect(s.trail == SwipeTrailStyle(color: NativeThemeTokens.tokens(for: appearance).keyLabel.withAlpha(0.8)))
            #expect(s.stripLabel == NativeThemeTokens.tokens(for: appearance).keyLabel)
            #expect(s.stripSeparator == NativeThemeTokens.tokens(for: appearance).keyLabel.withAlpha(0.18))
            #expect(s.stripKind == .plain)
        }
    }

    @Test func missingThemeFallsBackToNative() {
        // ThemeStore returns Native for anything missing / invalid (D-07); an empty store must give the Native skin.
        let defaults = UserDefaults(suiteName: "skin-test-\(UUID().uuidString)")!
        let theme = ThemeStore(defaults: defaults, photoDirectory: nil).loadSelected()
        #expect(theme == ThemePresets.native)
        #expect(KeyboardSkin(theme: theme, appearance: .dark, accessibility: .none) == .native(.dark))
    }

    @Test func themedSkinCarriesColoursAndBackdrop() {
        let s = KeyboardSkin(theme: ThemePresets.midnight, appearance: .dark, accessibility: .none)
        #expect(s.tokens.keyFill == ThemePresets.midnight.dark.keys.fill)
        #expect(s.tokens.actionKeyFill == ThemePresets.midnight.dark.keys.actionFill)
        #expect(s.backdrop.kind == .solid)
        #expect(s.backdrop.drawsAnything)
        #expect(s.trail.color == ThemePresets.midnight.dark.swipeTrail.color)
    }

    @Test func nativeGlassKeepsSystemBackdropAndTranslucentKeys() {
        let s = KeyboardSkin(theme: ThemePresets.nativeGlass, appearance: .light, accessibility: .none)
        #expect(!s.backdrop.drawsAnything)
        #expect(s.tokens.keyFill.alpha < 1)
        #expect(s.keyBorderWidth > 0)
    }

    @Test func reduceTransparencyMakesTheBackdropOpaqueAndKeysSolid() {
        let a = ThemeAccessibilitySettings(reduceTransparency: true)
        let s = KeyboardSkin(theme: ThemePresets.nativeGlass, appearance: .light, accessibility: a)
        #expect(s.backdrop.kind == .solid)
        #expect(s.backdrop.opacity == 1)
        #expect(s.tokens.keyFill.alpha == 1)
    }

    @Test func increaseContrastAddsBordersAndOpaqueSeparators() {
        let a = ThemeAccessibilitySettings(increaseContrast: true)
        let s = KeyboardSkin(theme: ThemePresets.native, appearance: .light, accessibility: a)
        #expect(s.keyBorderWidth >= 1)
        #expect(s.stripSeparator.alpha == 1)
        #expect(s.tokens.keyLabel.contrast(with: s.tokens.keyFill) >= 7)
    }

    @Test func boldTextRaisesTheWeightOneStep() {
        let s = KeyboardSkin(theme: ThemePresets.native, appearance: .light, accessibility: ThemeAccessibilitySettings(boldText: true))
        #expect(s.fontWeight == .medium)
        let hc = KeyboardSkin(theme: ThemePresets.highContrast, appearance: .light, accessibility: ThemeAccessibilitySettings(boldText: true))
        #expect(hc.fontWeight == .bold) // capped
    }

    @Test func backdropOpacityFollowsTheAppPreviewRule() {
        var t = ThemePresets.midnight
        t.dark.translucency = 0
        #expect(KeyboardSkin(theme: t, appearance: .dark, accessibility: .none).backdrop.opacity == 0.5)
        t.dark.translucency = 1
        #expect(KeyboardSkin(theme: t, appearance: .dark, accessibility: .none).backdrop.opacity == 1)
    }

    @Test func gradientAngleConvention() {
        var b = BackdropSpec.system
        b.gradientAngle = 90 // top to bottom
        #expect(abs(b.gradientPoints.start.y - 0) < 1e-9 && abs(b.gradientPoints.end.y - 1) < 1e-9)
        b.gradientAngle = 0 // left to right
        #expect(abs(b.gradientPoints.start.x - 0) < 1e-9 && abs(b.gradientPoints.end.x - 1) < 1e-9)
    }
}
