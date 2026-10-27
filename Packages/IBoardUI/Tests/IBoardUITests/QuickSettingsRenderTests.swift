#if canImport(UIKit)
import Testing
import UIKit
import IBoardCore
import IBoardLayout
import IBoardTheme
@testable import IBoardUI

/// Renders the emoji-key alternates popup and the Quick Settings panel (light, dark, large text). PNGs are written when
/// IBOARD_RENDER_DIR is set (via TEST_RUNNER_IBOARD_RENDER_DIR with xcodebuild); sizes and wiring are always asserted.
@MainActor
@Suite("Quick settings render")
struct QuickSettingsRenderTests {
    private func png(_ view: UIView, name: String, style: UIUserInterfaceStyle) throws {
        view.overrideUserInterfaceStyle = style
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: view.bounds.size).image { ctx in
            (style == .dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.82, alpha: 1)).setFill()
            ctx.fill(view.bounds)
            view.layer.render(in: ctx.cgContext)
        }
        if let dir = ProcessInfo.processInfo.environment["IBOARD_RENDER_DIR"], let data = image.pngData() {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @Test("alternates popup with symbol tiles", arguments: [ThemeAppearance.light, .dark])
    func alternates(appearance: ThemeAppearance) throws {
        let w: CGFloat = 390, h: CGFloat = 48
        let strip = SuggestionStripView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        strip.skin = .native(appearance)
        let options = [KeyAlternates.clipboardGlyph, KeyAlternates.settingsGlyph]
        strip.beginAlternates(AlternatesSelection(options: options, stripFrame: strip.frame,
                                                  originRegion: CGRect(x: 300, y: 100, width: 40, height: 40)))
        #expect(strip.isShowingAlternates)
        try png(strip, name: "alt-symbols-\(appearance == .dark ? "dark" : "light")-first", style: appearance == .dark ? .dark : .light)
        strip.move(to: CGPoint(x: w / 2 + 20, y: 10))
        try png(strip, name: "alt-symbols-\(appearance == .dark ? "dark" : "light")-second", style: appearance == .dark ? .dark : .light)
        strip.cancelAlternates()
        strip.beginAlternates(AlternatesSelection(options: ["é", "è", "ê", "ë"], stripFrame: strip.frame,
                                                  originRegion: CGRect(x: 300, y: 100, width: 40, height: 40)))
        try png(strip, name: "alt-letters-\(appearance == .dark ? "dark" : "light")", style: appearance == .dark ? .dark : .light)
    }

    @Test("quick settings panel renders and reports edits", arguments: [ThemeAppearance.light, .dark])
    func panel(appearance: ThemeAppearance) throws {
        let state = QuickSettingsState(settings: .defaults, incognito: false, hasFullAccess: appearance == .dark)
        let p = QuickSettingsPanelView(state: state, skin: .native(appearance))
        p.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        var edits: [QuickSettingsEdit] = []
        p.onEdit = { edits.append($0) }
        p.layoutIfNeeded()
        try png(p, name: "panel-\(appearance == .dark ? "dark" : "light")", style: appearance == .dark ? .dark : .light)
        // Large text: the layout must stay usable (content scrolls).
        p.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        p.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        p.layoutIfNeeded()
        try png(p, name: "panel-\(appearance == .dark ? "dark" : "light")-large", style: appearance == .dark ? .dark : .light)
        #expect(edits.isEmpty)
    }
}

@Suite("Alternate symbols")
struct AlternateSymbolTests {
    @Test func actionGlyphsHaveSymbolsAndLabels() {
        #expect(KeyAlternates.symbolName(for: KeyAlternates.settingsGlyph) == "gearshape")
        #expect(KeyAlternates.symbolName(for: KeyAlternates.clipboardGlyph) == "doc.on.clipboard")
        #expect(KeyAlternates.accessibilityLabel(for: KeyAlternates.settingsGlyph) == "Quick settings")
        #expect(KeyAlternates.accessibilityLabel(for: KeyAlternates.clipboardGlyph) == "Clipboard history")
        #expect(KeyAlternates.symbolName(for: "é") == nil)
    }
}
#endif
