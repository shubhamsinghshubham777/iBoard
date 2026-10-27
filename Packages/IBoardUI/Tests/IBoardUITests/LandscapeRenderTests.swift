#if canImport(UIKit)
import Testing
import UIKit
import IBoardLayout
@testable import IBoardUI

/// F13 render check: lays out the landscape keyboard on a KeyGridView and renders it. Writes PNGs only when
/// IBOARD_RENDER_DIR is set; always asserts that the render has the right size.
@MainActor
@Suite("Landscape render (F13)")
struct LandscapeRenderTests {
    @Test("landscape grid renders at mini / 12 / Pro Max", arguments: [(812.0, 44.0), (844.0, 47.0), (932.0, 59.0)])
    func render(width: Double, inset: Double) throws {
        let safe = LayoutInsets(left: CGFloat(inset), bottom: 21, right: CGFloat(inset))
        let traits = LayoutTraits(orientation: .landscape)
        var settings = LayoutSettings(); settings.emojiKey = true
        let h = LayoutEngine.preferredHeight(width: CGFloat(width), safeArea: safe, traits: traits, kind: .letters, settings: settings)
        let layout = LayoutEngine.layout(containerSize: CGSize(width: width, height: h), safeArea: safe, traits: traits, kind: .letters, settings: settings)
        let grid = KeyGridView(frame: CGRect(x: 0, y: 0, width: width, height: h))
        grid.showsFlickHints = true
        grid.apply(layout: layout)
        grid.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: grid.bounds.size).image { ctx in
            UIColor.systemGray5.setFill(); ctx.fill(grid.bounds)
            grid.layer.render(in: ctx.cgContext)
        }
        #expect(image.size.width == CGFloat(width))
        if let dir = ProcessInfo.processInfo.environment["IBOARD_RENDER_DIR"], let data = image.pngData() {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("landscape-\(Int(width)).png"))
        }
    }
}
#endif
