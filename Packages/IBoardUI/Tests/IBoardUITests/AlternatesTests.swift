import CoreGraphics
import Foundation
import Testing
import IBoardLayout
@testable import IBoardUI

private let layout = LayoutEngine.layout(
    containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters
)

private func center(_ id: KeyIdentity) -> CGPoint {
    let f = layout.firstKey(id)!.frame
    return CGPoint(x: f.midX, y: f.midY)
}

private final class Sink {
    var events: [KeyEvent] = []
    func callAsFunction(_ e: KeyEvent) { events.append(e) }
    var nonHighlight: [KeyEvent] { events.filter { if case .highlight = $0 { false } else { true } } }
}

@Test func tableLookups() {
    #expect(KeyAlternates.options(for: .letter("e"))?.first == "è")
    #expect(KeyAlternates.options(for: .letter("e"), uppercase: true)?.first == "È")
    #expect(KeyAlternates.options(for: .letter("q")) == nil)
    #expect(KeyAlternates.options(for: .domainSuffix(".com"))?.contains(".in") == true)
    #expect(KeyAlternates.options(for: .space) == nil)
}

@Test func longPressFiresAfter450msAndTapStillInserts() {
    var m = KeyboardInputMachine(layout: layout)
    let s = Sink()
    let e = layout.firstKey(.letter("e"))!
    m.touchDown(id: 1, at: center(.letter("e")), time: 0) { s($0) }
    #expect(m.nextDeadline == 0.45)
    m.tick(now: 0.4) { s($0) }
    #expect(s.nonHighlight.isEmpty)
    m.tick(now: 0.46) { s($0) }
    #expect(s.nonHighlight == [.alternatesBegan(keyIndex: e.id)])
    m.touchMoved(id: 1, to: CGPoint(x: 100, y: 20)) { s($0) }
    m.touchUp(id: 1, at: CGPoint(x: 100, y: 20), time: 0.5) { s($0) }
    #expect(s.nonHighlight.suffix(2) == [.alternatesMoved(CGPoint(x: 100, y: 20)), .alternatesEnded(CGPoint(x: 100, y: 20))])
    #expect(m.activeTouchCount == 0)
    #expect(m.nextDeadline == nil)

    // A quick tap on the same key inserts the letter and never arms alternates afterwards.
    let t = Sink()
    m.touchDown(id: 2, at: center(.letter("e")), time: 1) { t($0) }
    m.touchUp(id: 2, time: 1.1) { t($0) }
    m.tick(now: 2) { t($0) }
    #expect(t.nonHighlight == [.insert("e")])
}

@Test func keysWithoutAlternatesHaveNoDeadline() {
    var m = KeyboardInputMachine(layout: layout)
    m.touchDown(id: 1, at: center(.space), time: 0) { _ in }
    #expect(m.nextDeadline == nil)
}

@Test func cancelDuringAlternatesEmitsCancelled() {
    var m = KeyboardInputMachine(layout: layout)
    let s = Sink()
    m.touchDown(id: 1, at: center(.letter("a")), time: 0) { s($0) }
    m.tick(now: 0.5) { s($0) }
    m.touchCancelled(id: 1) { s($0) }
    #expect(s.nonHighlight.last == .alternatesCancelled)
}

@Test func selectionDefaultSlideAndCancel() {
    let strip = layout.stripFrame
    let origin = layout.firstKey(.letter("e"))!.touchRegion
    var sel = AlternatesSelection(options: ["è", "é", "ê", "ë"], stripFrame: strip, originRegion: origin)
    #expect(sel.highlighted == 0)
    // Jitter on the origin key before leaving it keeps the default.
    sel.move(to: CGPoint(x: origin.midX + 2, y: origin.midY))
    #expect(sel.highlighted == 0)
    // Slide onto the strip over the third cell.
    let c2 = sel.cellFrame(2)
    sel.move(to: CGPoint(x: c2.midX, y: strip.midY))
    #expect(sel.highlighted == 2)
    // Far right of the row clamps to the last cell; far left to the first.
    sel.move(to: CGPoint(x: strip.maxX + 50, y: strip.midY))
    #expect(sel.highlighted == 3)
    sel.move(to: CGPoint(x: -50, y: strip.midY))
    #expect(sel.highlighted == 0)
    // Elsewhere on the keys keeps the highlight; back on the origin key cancels.
    sel.move(to: CGPoint(x: strip.midX, y: strip.maxY + 5))
    sel.move(to: CGPoint(x: origin.midX, y: origin.midY))
    #expect(sel.highlighted == nil)
    #expect(sel.end(at: CGPoint(x: origin.midX, y: origin.midY)) == nil)
}

@Test func selectionReleaseCommitsHighlighted() {
    let strip = layout.stripFrame
    let origin = layout.firstKey(.letter("e"))!.touchRegion
    var sel = AlternatesSelection(options: ["è", "é", "ê"], stripFrame: strip, originRegion: origin)
    #expect(sel.end(at: CGPoint(x: sel.cellFrame(1).midX, y: strip.midY)) == "é")
    var def = AlternatesSelection(options: ["è", "é"], stripFrame: strip, originRegion: origin)
    #expect(def.end(at: CGPoint(x: origin.midX, y: origin.midY)) == "è") // never left the key: default commits
}

@Test func resizeMathInterpolatesAndClamps() {
    // height(s) = 44 + 216 s + 0  ->  h0 = 44, h1 = 260
    #expect(ResizeMath.scale(forHeight: 260, height0: 44, height1: 260) == 1)
    #expect(abs(ResizeMath.scale(forHeight: 44 + 216 * 1.2, height0: 44, height1: 260) - 1.2) < 1e-9)
    #expect(ResizeMath.scale(forHeight: 100, height0: 44, height1: 260) == 0.8)
    #expect(ResizeMath.scale(forHeight: 900, height0: 44, height1: 260) == 1.4)
    #expect(ResizeMath.scale(forHeight: 200, height0: 100, height1: 100) == 1)
}

@Test func preferredHeightIsLinearInScaleSoResizeMathInverts() {
    let t = LayoutTraits()
    func h(_ s: CGFloat) -> CGFloat {
        LayoutEngine.preferredHeight(width: 390, traits: t, kind: .letters, settings: LayoutSettings(heightScale: s))
    }
    let s = ResizeMath.scale(forHeight: h(1.25), height0: h(0), height1: h(1))
    #expect(abs(s - 1.25) < 1e-6)
    #expect(h(1.4) > h(1) && h(0.8) < h(1))
}

@Test func everyLetterOffersItsHintSymbolFirstOnALongPress() {
    #expect(KeyAlternates.longPressOptions(for: .letter("q")) == ["1"])
    #expect(KeyAlternates.longPressOptions(for: .letter("e")) == ["3", "è", "é", "ê", "ë", "ē", "ė", "ę"])
    #expect(KeyAlternates.longPressOptions(for: .letter("e"), uppercase: true)?.first == "3")
    #expect(KeyAlternates.longPressOptions(for: .space) == nil)
    // Flick down still types the first accent, not the symbol.
    #expect(KeyFlick.text(for: .letter("e"), direction: .down, uppercase: false) == "è")
}

@Test func theEmojiKeyOffersTheSettingsShortcutOnALongPress() {
    #expect(KeyAlternates.longPressOptions(for: .emoji) == [KeyAlternates.settingsGlyph])
    #expect(KeyAlternates.longPressOptions(for: .emoji, clipboardEntry: true) == [KeyAlternates.clipboardGlyph, KeyAlternates.settingsGlyph])
    #expect(KeyFlick.text(for: .emoji, direction: .down, uppercase: false) == nil)
}

@Test func releaseThatNeverLeftTheOriginKeyInsertsTheKeysOwnLetter() {
    let origin = CGRect(x: 100, y: 100, width: 36, height: 42)
    var sel = AlternatesSelection(options: ["î", "ì"], stripFrame: CGRect(x: 0, y: 0, width: 390, height: 44),
                                  originRegion: origin, originText: "i")
    #expect(sel.end(at: CGPoint(x: origin.midX, y: origin.midY)) == "i")
}

@Test func releaseOverTheStripStillPicksTheAccent() {
    let origin = CGRect(x: 100, y: 100, width: 36, height: 42)
    var sel = AlternatesSelection(options: ["î", "ì"], stripFrame: CGRect(x: 0, y: 0, width: 390, height: 44),
                                  originRegion: origin, originText: "i")
    #expect(sel.end(at: CGPoint(x: 160, y: 20)) == "î")
}
