#if canImport(UIKit)
import Testing
import UIKit
import IBoardLayout
@testable import IBoardUI

/// Snapshot-style render checks for the faint hint characters on letter keys: every hint sits at the same inset from
/// its key's top-right corner whatever the letter or the glyph shape, and never touches the main letter.
@MainActor
@Suite("Hint placement")
struct HintPlacementTests {
    struct Ink { var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1; var any: Bool { maxX >= 0 } }

    /// Ink (alpha > 8) bounds of a rendered glyph, in points.
    static func ink(_ image: CGImage, scale: CGFloat) -> CGRect? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) // bitmap row 0 is the top row
        var r = Ink()
        for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4 + 3] > 8 {
            let top = y
            r.minX = min(r.minX, x); r.maxX = max(r.maxX, x + 1); r.minY = min(r.minY, top); r.maxY = max(r.maxY, top + 1)
        } }
        guard r.any else { return nil }
        return CGRect(x: CGFloat(r.minX) / scale, y: CGFloat(r.minY) / scale,
                      width: CGFloat(r.maxX - r.minX) / scale, height: CGFloat(r.maxY - r.minY) / scale)
    }

    static let scale: CGFloat = 3
    static let keyHeight: CGFloat = 43

    func cache() -> GlyphCache {
        let c = GlyphCache()
        c.configure(skin: .native(.light), scale: Self.scale, keyHeight: Self.keyHeight)
        return c
    }

    func inkOf(_ c: GlyphCache, _ spec: GlyphSpec) throws -> CGRect {
        let image = try #require(c.image(for: spec))
        return try #require(Self.ink(image, scale: Self.scale))
    }

    static let letters = Array("qwertyuiopasdfghjklzxcvbnm").map(String.init)
    static let widths: [CGFloat] = [29, 32, 35, 39]

    @Test("every hint has the same inset from the key's top-right corner (hint ink centre), for every key width")
    func sameInsetForAllKeys() throws {
        let c = cache()
        let expected = HintPlacement.box(keyWidth: 100) // inset math is width independent
        let wantRight = 100 - expected.midX, wantTop = expected.midY
        var checked = 0
        for width in Self.widths {
            for letter in Self.letters {
                guard let hint = KeyFlick.hint(for: .letter(letter)) else { continue }
                // " " as the main glyph: the bitmap holds the hint alone.
                let image = try #require(c.image(for: .hinted(" ", hint: hint, upper: false, width: Int(width * 4))))
                #expect(CGFloat(image.width) / Self.scale == width, "bitmap is exactly the key width")
                let ink = try #require(Self.ink(image, scale: Self.scale), "hint \(hint) has ink")
                let right = width - ink.midX, top = ink.midY
                #expect(abs(right - wantRight) <= 0.5, "\(letter)/\(hint) w\(width): right inset \(right) vs \(wantRight)")
                #expect(abs(top - wantTop) <= 0.5, "\(letter)/\(hint) w\(width): top inset \(top) vs \(wantTop)")
                #expect(ink.maxX <= width - HintPlacement.rightInset + 0.5, "inside the corner margin")
                checked += 1
            }
        }
        #expect(checked >= 26 * Self.widths.count - 4)
    }

    @Test("hint ink never touches the main letter, lower and upper case, on narrow keys", arguments: [false, true])
    func noOverlapWithLetter(upper: Bool) throws {
        let c = cache()
        for width in [29, 32, 35] as [CGFloat] {
            for letter in Self.letters {
                guard let hint = KeyFlick.hint(for: .letter(letter)) else { continue }
                let shown = upper ? letter.uppercased() : letter
                let hintOnly = try inkOf(c, .hinted(" ", hint: hint, upper: upper, width: Int(width * 4)))
                let letterOnly = try inkOf(c, .hinted(shown, hint: " ", upper: upper, width: Int(width * 4)))
                #expect(!hintOnly.intersects(letterOnly),
                        "\(shown)/\(hint) w\(width): hint \(hintOnly) overlaps letter \(letterOnly)")
            }
        }
    }

    @Test("hint size and opacity are shared; bold text switches the weight only")
    func sizeAndOpacityShared() {
        #expect(HintPlacement.font(bold: false).pointSize == HintPlacement.font(bold: true).pointSize)
        #expect(HintPlacement.alpha == 0.4)
        // Monospaced face: digits and symbols share one advance, so the box centring is not glyph-width dependent.
        let f = HintPlacement.font(bold: false)
        let widths = Set(["1", "0", "@", "%", "-"].map { ($0 as NSString).size(withAttributes: [.font: f]).width })
        #expect(widths.count == 1)
    }

    /// Writes before / after-style PNGs of a full keyboard render when IBOARD_RENDER_DIR is set.
    @Test("full letters grid renders with hints (PNG when IBOARD_RENDER_DIR is set)")
    func gridRender() throws {
        let width: CGFloat = 390
        let safe = LayoutInsets(left: 0, bottom: 0, right: 0)
        var settings = LayoutSettings(punctuationKeys: true, emojiKey: true); settings.numberRow = false
        let traits = LayoutTraits()
        let h = LayoutEngine.preferredHeight(width: width, safeArea: safe, traits: traits, kind: .letters, settings: settings)
        let layout = LayoutEngine.layout(containerSize: CGSize(width: width, height: h), safeArea: safe, traits: traits, kind: .letters, settings: settings)
        for (name, skin, style) in [("light", KeyboardSkin.native(.light), UIUserInterfaceStyle.light), ("dark", KeyboardSkin.native(.dark), .dark)] {
            let grid = KeyGridView(frame: CGRect(x: 0, y: 0, width: width, height: h))
            grid.overrideUserInterfaceStyle = style
            grid.skin = skin
            grid.showsFlickHints = true
            grid.apply(layout: layout)
            grid.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 3
            let image = UIGraphicsImageRenderer(size: grid.bounds.size, format: format).image { ctx in
                (style == .dark ? UIColor(white: 0.1, alpha: 1) : UIColor(white: 0.82, alpha: 1)).setFill()
                ctx.fill(grid.bounds)
                grid.layer.render(in: ctx.cgContext)
            }
            #expect(image.size.width == width)
            if let dir = ProcessInfo.processInfo.environment["IBOARD_RENDER_DIR"], let data = image.pngData() {
                let tag = ProcessInfo.processInfo.environment["IBOARD_RENDER_TAG"] ?? "after"
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("hints-\(tag)-\(name).png"))
            }
        }
    }
}
#endif
