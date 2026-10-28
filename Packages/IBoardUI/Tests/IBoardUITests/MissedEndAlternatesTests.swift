import CoreGraphics
import Foundation
import Testing
import IBoardLayout
@testable import IBoardUI

/// A lift with no position (a repeated touch id stood in for a missed end) while the popup is open used to emit
/// `alternatesEnded(.zero)`, which the strip resolves to the first option: i became î.
@Test func missedEndWhileAlternatesOpenTypesOwnLetterNotFirstOption() {
    let layout = LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260),
                                     traits: LayoutTraits(needsInputModeSwitchKey: false), kind: .letters)
    var m = KeyboardInputMachine(layout: layout)
    var events: [KeyEvent] = []
    func center(_ s: String) -> CGPoint { let f = layout.firstKey(.letter(s))!.frame; return CGPoint(x: f.midX, y: f.midY) }
    m.touchDown(id: 1, at: center("i"), time: 0) { events.append($0) }
    m.tick(now: 0.5) { events.append($0) }
    #expect(events.contains { if case .alternatesBegan = $0 { true } else { false } })
    events.removeAll()
    m.touchDown(id: 1, at: center("n"), time: 0.6) { events.append($0) } // repeated id: missed end
    #expect(!events.contains { if case .alternatesEnded = $0 { true } else { false } })
    #expect(events.compactMap { if case .insert(let s) = $0 { s } else { nil } } == ["i"])
    m.touchUp(id: 1, at: center("n"), time: 0.65) { events.append($0) }
    #expect(events.compactMap { if case .insert(let s) = $0 { s } else { nil } } == ["i", "n"])
}
