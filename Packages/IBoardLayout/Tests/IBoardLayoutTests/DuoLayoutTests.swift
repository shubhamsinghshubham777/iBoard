import CoreGraphics
import Foundation
import Testing
@testable import IBoardLayout

// iPhone Duo layout rules (M11-01..04). Sizes are raw container sizes; no device model is ever consulted.

private let innerLandscape = LayoutTraits(displayClass: .duoInner, orientation: .landscape)
private let innerPortrait = LayoutTraits(displayClass: .duoInner, orientation: .portrait)

private func splitLayout(
    _ kind: LayoutKind, traits: LayoutTraits = innerLandscape, size: CGSize = CGSize(width: 951, height: 230),
    settings: LayoutSettings? = nil, safe: LayoutInsets = .zero
) -> KeyboardLayout {
    LayoutEngine.layout(
        containerSize: size, safeArea: safe, traits: traits, kind: kind,
        settings: settings ?? LayoutSettings.defaults(for: traits)
    )
}

@Suite("Duo outer (M11-01)")
struct DuoOuterTests {
    @Test("outer portrait: lower default height ratio than a phone, key width capped")
    func outerPortrait() {
        let outer = LayoutTraits(displayClass: .duoOuter)
        let hOuter = LayoutEngine.preferredHeight(width: 466, traits: outer, kind: .letters)
        let hPhone = LayoutEngine.preferredHeight(width: 466, traits: LayoutTraits(), kind: .letters)
        #expect(hOuter < hPhone)
        let l = LayoutEngine.layout(containerSize: CGSize(width: 466, height: hOuter), traits: outer, kind: .letters)
        #expect(l.metrics.keyWidth <= LayoutMetrics.duoOuterMaxKeyWidthPortrait + 1e-9)
        #expect(l.metrics.mode == .standard)
        #expect(l.foldBand == nil && l.stripSegments == [l.stripFrame])
    }

    @Test("outer landscape: key width capped, height ratio unchanged (landscape is already short)")
    func outerLandscape() {
        let t = LayoutTraits(displayClass: .duoOuter, orientation: .landscape)
        let tp = LayoutTraits(displayClass: .duoInner, orientation: .landscape)
        #expect(
            LayoutEngine.preferredHeight(width: 678, traits: t, kind: .letters)
                == LayoutEngine.preferredHeight(width: 678, traits: tp, kind: .letters)
        )
        let l = LayoutEngine.layout(containerSize: CGSize(width: 678, height: 200), traits: t, kind: .letters)
        #expect(l.metrics.keyWidth <= LayoutMetrics.duoOuterMaxKeyWidthLandscape + 1e-9)
    }

    @Test("phones are unaffected by the Duo tuning")
    func phoneUnchanged() {
        #expect(LayoutEngine.preferredHeight(width: 390, traits: LayoutTraits(), kind: .letters) == 295)
    }
}

@Suite("Duo inner portrait (M11-02)")
struct DuoInnerPortraitTests {
    @Test("defaults: number row on, no split, key width capped, hit regions reach both edges")
    func defaults() {
        let s = LayoutSettings.defaults(for: innerPortrait)
        #expect(s.numberRow && !s.splitPortrait && s.splitLandscape && !s.fillToFold)  // landscape split is the other orientation's default
        let h = LayoutEngine.preferredHeight(width: 669, traits: innerPortrait, kind: .letters, settings: s)
        let l = LayoutEngine.layout(containerSize: CGSize(width: 669, height: h), traits: innerPortrait, kind: .letters, settings: s)
        #expect(l.metrics.mode == .standard && l.foldBand == nil)
        #expect(l.metrics.keyWidth <= LayoutMetrics.duoInnerMaxKeyWidth + 1e-9)
        #expect(l.firstKey(.symbol("1")) != nil && l.keys.filter { $0.row == 0 }.count == 10)
        let y = l.firstKey(.letter("q"))!.frame.midY
        #expect(l.key(at: CGPoint(x: 0, y: y))?.identity == .letter("q"))
        #expect(l.key(at: CGPoint(x: 669, y: y))?.identity == .letter("p"))
    }

    @Test("the portrait split flag is honoured on the inner display (pinch toggle), and only there")
    func portraitSplitFlag() {
        var s = LayoutSettings.defaults(for: innerPortrait)
        s.splitPortrait = true
        let l = splitLayout(.letters, traits: innerPortrait, size: CGSize(width: 669, height: 300), settings: s)
        guard case .split = l.metrics.mode else { Issue.record("expected split"); return }
        let phone = LayoutEngine.layout(
            containerSize: CGSize(width: 390, height: 260), traits: LayoutTraits(), kind: .letters, settings: s
        )
        #expect(phone.metrics.mode == .standard)
    }
}

@Suite("Duo inner landscape split (M11-03)")
struct DuoSplitTests {
    struct Variant: Sendable, CustomTestStringConvertible {
        let name: String
        let traits: LayoutTraits
        let settings: LayoutSettings
        var testDescription: String { name }
    }

    static let variants: [Variant] = {
        var out: [Variant] = []
        let base = LayoutSettings.defaults(for: innerLandscape)
        out.append(Variant(name: "default", traits: innerLandscape, settings: base))
        out.append(Variant(name: "globe", traits: LayoutTraits(displayClass: .duoInner, orientation: .landscape, needsInputModeSwitchKey: true), settings: base))
        out.append(Variant(name: "email", traits: LayoutTraits(displayClass: .duoInner, orientation: .landscape, keyboardKind: .emailAddress), settings: base))
        out.append(Variant(name: "url", traits: LayoutTraits(displayClass: .duoInner, orientation: .landscape, keyboardKind: .url), settings: base))
        var p = base; p.punctuationKeys = true; p.numberRow = true
        out.append(Variant(name: "punct+numrow+globe", traits: LayoutTraits(displayClass: .duoInner, orientation: .landscape, needsInputModeSwitchKey: true), settings: p))
        var wide = base; wide.centreGap = CentreGap(centerX: 475.5, width: 80)
        out.append(Variant(name: "wide-gap", traits: innerLandscape, settings: wide))
        var narrow = base; narrow.centreGap = CentreGap(centerX: 475.5, width: 4)
        out.append(Variant(name: "narrow-gap-raised", traits: innerLandscape, settings: narrow))
        var off = base; off.centreGap = CentreGap(centerX: 440, width: 40)
        out.append(Variant(name: "off-centre", traits: innerLandscape, settings: off))
        var portrait = LayoutSettings.defaults(for: innerPortrait); portrait.splitPortrait = true
        out.append(Variant(name: "portrait-split", traits: innerPortrait, settings: portrait))
        return out
    }()

    static let sizes: [(CGSize, LayoutInsets)] = [
        (CGSize(width: 951, height: 206), .zero),
        (CGSize(width: 951, height: 230), LayoutInsets(left: 20, bottom: 12, right: 20)),
        (CGSize(width: 669, height: 300), .zero),
        (CGSize(width: 700, height: 180), .zero),
    ]

    /// ACCEPTANCE (F18): no key cap and no strip piece inside the fold band; keys fit and never overlap.
    @Test("no key or strip control inside the fold band; keys stay in bounds", arguments: variants, LayoutKind.allCases)
    func foldBandInvariant(v: Variant, kind: LayoutKind) {
        for (size, safe) in Self.sizes {
            let l = splitLayout(kind, traits: v.traits, size: size, settings: v.settings, safe: safe)
            if kind.isPad {
                #expect(l.foldBand == nil, "pads are never split")
                continue
            }
            guard let band = l.foldBand, case .split(let gap) = l.metrics.mode else {
                Issue.record("\(v.name) \(kind) \(size): expected split"); continue
            }
            #expect(band.width >= DuoGeometry.foldBandWidth - 1e-9)
            #expect(abs(band.midX - gap.centerX) < 1e-9)
            for k in l.keys {
                #expect(k.frame.maxX <= band.minX + 1e-6 || k.frame.minX >= band.maxX - 1e-6,
                        "\(v.name) \(kind) \(size): \(k.identity) enters the fold band")
                #expect(k.frame.minX >= safe.left - 1e-6 && k.frame.maxX <= size.width - safe.right + 1e-6)
                #expect(k.frame.maxY <= size.height + 1e-6 && k.frame.width > 0)
            }
            for s in l.stripSegments {
                #expect(s.maxX <= band.minX + 1e-6 || s.minX >= band.maxX - 1e-6, "strip segment enters the band")
            }
            #expect(l.stripSegments.count == 2)
            for i in 0..<l.keys.count {
                for j in (i + 1)..<max(l.keys.count, i + 1) {
                    let r = l.keys[i].frame.intersection(l.keys[j].frame)
                    #expect(r.isNull || r.width * r.height < 1e-6, "\(l.keys[i].identity) overlaps \(l.keys[j].identity)")
                }
            }
        }
    }

    /// Identity and ordering must equal the non-split layout (swipe templates, touch model, input machine).
    @Test("key identities and order equal the non-split layout", arguments: variants, LayoutKind.allCases)
    func identityOrder(v: Variant, kind: LayoutKind) {
        var plain = v.settings
        plain.splitLandscape = false; plain.splitPortrait = false
        let size = CGSize(width: 951, height: 230)
        let a = LayoutEngine.layout(containerSize: size, traits: v.traits, kind: kind, settings: v.settings)
        let b = LayoutEngine.layout(containerSize: size, traits: v.traits, kind: kind, settings: plain)
        #expect(a.keys.map(\.identity) == b.keys.map(\.identity))
        #expect(a.keys.map(\.row) == b.keys.map(\.row))
        #expect(a.keys.map(\.id) == b.keys.map(\.id))
    }

    @Test("split halves: letters are the same set, left letters are left of the fold, right letters right of it")
    func lettersSides() {
        let l = splitLayout(.letters)
        let band = l.foldBand!
        for c in "qwertasdfgzxcv" { #expect(l.firstKey(.letter(String(c)))!.frame.maxX <= band.minX) }
        for c in "yuiophjklbnm" { #expect(l.firstKey(.letter(String(c)))!.frame.minX >= band.maxX) }
        #expect(l.firstKey(.shift)!.frame.maxX <= band.minX && l.firstKey(.delete)!.frame.minX >= band.maxX)
        #expect(l.firstKey(.space)!.frame.maxX <= band.minX && l.firstKey(.returnKey(.default))!.frame.minX >= band.maxX)
        #expect(l.keys.count == splitLayout(.letters, settings: LayoutSettings()).keys.count)
    }

    @Test("gap width is at least the fold band and an explicit wider gap is honoured")
    func gapWidth() {
        var s = LayoutSettings.defaults(for: innerLandscape)
        s.centreGap = CentreGap(centerX: 475.5, width: 5)
        #expect(splitLayout(.letters, settings: s).foldBand!.width == DuoGeometry.foldBandWidth)
        s.centreGap = CentreGap(centerX: 475.5, width: 90)
        let l = splitLayout(.letters, settings: s)
        #expect(l.foldBand!.width == 90)
        let q = l.firstKey(.letter("t"))!, y = l.firstKey(.letter("y"))!
        #expect(y.frame.minX - q.frame.maxX >= 90 - 1e-6)
        #expect(splitLayout(.letters).foldBand!.minX == 475.5 - DuoGeometry.foldBandWidth / 2)
    }

    /// Swipe gestures pass through the gap: every point of the band (and a straight swipe line across it)
    /// resolves, the resolved key moves monotonically left to right, and nothing is nil.
    @Test("hit model continues across the gap; a swipe across the fold resolves every sample")
    func hitAcrossGap() {
        let l = splitLayout(.letters)
        let band = l.foldBand!
        let row = l.keys.filter { $0.row == 0 }   // 'qwertyuiop' (number row is off)
        let y = row[0].frame.midY
        #expect(l.hit(at: CGPoint(x: band.midX, y: y)) != nil)
        var last = -1
        var x = row[0].frame.midX
        while x <= row.last!.frame.midX {
            let h = l.hit(at: CGPoint(x: x, y: y))
            #expect(h != nil)
            let idx = row.firstIndex { $0.id == h?.keyIndex } ?? -1
            #expect(idx >= last, "swipe resolution went backwards at x=\(x)")
            last = idx
            x += 1
        }
        #expect(last == row.count - 1)
        // Left/right of the fold boundary pick the nearer half-key (t | y).
        let t = l.firstKey(.letter("t"))!, yk = l.firstKey(.letter("y"))!
        let mid = (t.frame.maxX + yk.frame.minX) / 2
        #expect(l.key(at: CGPoint(x: mid - 0.1, y: y))?.identity == .letter("t"))
        #expect(l.key(at: CGPoint(x: mid + 0.1, y: y))?.identity == .letter("y"))
        // Dense sweep: regions still tile the whole key area (no hole in or near the band).
        for px in stride(from: 0.0, through: 951.0, by: 3.0) {
            for py in stride(from: l.keyArea.minY, through: l.keyArea.maxY, by: 3.0) {
                #expect(l.hit(at: CGPoint(x: px, y: py)) != nil)
            }
        }
    }

    @Test("split flag off or non-Duo display: centreGap is ignored and layout is the standard one")
    func centreGapGatedByMode() {
        let size = CGSize(width: 951, height: 206)
        let gap = LayoutSettings(centreGap: CentreGap(centerX: 475.5, width: 27))
        for traits in [innerLandscape, LayoutTraits(orientation: .landscape), LayoutTraits(displayClass: .duoOuter, orientation: .landscape)] {
            let plain = LayoutEngine.layout(containerSize: size, traits: traits, kind: .letters)
            let withGap = LayoutEngine.layout(containerSize: size, traits: traits, kind: .letters, settings: gap)
            #expect(plain == withGap)
        }
        var forced = LayoutSettings(splitLandscape: true)
        forced.centreGap = nil
        let phone = LayoutEngine.layout(containerSize: size, traits: LayoutTraits(orientation: .landscape), kind: .letters, settings: forced)
        #expect(phone.metrics.mode == .standard && phone.foldBand == nil)
    }

    @Test("settings stored before the Duo fields existed still decode")
    func tolerantDecode() throws {
        let old = #"{"numberRow":true,"heightScale":1,"punctuationKeys":false,"currency":{"primary":"$","others":["€","£","¥"]}}"#
        let s = try JSONDecoder().decode(LayoutSettings.self, from: Data(old.utf8))
        #expect(s.numberRow && !s.splitLandscape && !s.fillToFold && s.centreGap == nil)
        let round = try JSONDecoder().decode(LayoutSettings.self, from: JSONEncoder().encode(LayoutSettings.defaults(for: innerLandscape)))
        #expect(round == LayoutSettings.defaults(for: innerLandscape))
    }

    @Test("default split key size is capped and halves hug the outer edges")
    func splitMetrics() {
        let l = splitLayout(.letters)
        #expect(l.metrics.keyWidth <= LayoutMetrics.splitMaxKeyWidth + 1e-9 && l.metrics.keyWidth > 40)
        #expect(abs(l.firstKey(.shift)!.frame.minX - l.metrics.splitLeftMinX) < 1e-9)
        #expect(abs(l.firstKey(.delete)!.frame.maxX - l.metrics.splitRightMaxX) < 1e-9)
    }
}

@Suite("Duo laptop fill to fold (M11-04)")
struct DuoFillToFoldTests {
    static let size = CGSize(width: 951, height: DuoGeometry.fillToFoldHeight(innerLandscapeHeight: 669))

    private func fold(_ kind: LayoutKind = .letters) -> KeyboardLayout {
        var s = LayoutSettings.defaults(for: innerLandscape)
        s.fillToFold = true
        return LayoutEngine.layout(containerSize: Self.size, traits: innerLandscape, kind: kind, settings: s)
    }

    @Test("snap height is half of the inner landscape height; snapping obeys the tolerance")
    func snap() {
        #expect(Self.size.height == 334.5)
        #expect(DuoGeometry.snappedHeight(proposed: 334.5 + 10, innerLandscapeHeight: 669) == (334.5, true))
        #expect(DuoGeometry.snappedHeight(proposed: 334.5 - DuoGeometry.snapTolerance - 1, innerLandscapeHeight: 669).snapped == false)
        #expect(DuoGeometry.snappedHeight(proposed: 200, innerLandscapeHeight: 669) == (200, false))
    }

    @Test("no split, number row on even when the setting is off, bigger keys than split, one strip")
    func shape() {
        let l = fold()
        #expect(l.metrics.mode == .fillToFold && l.foldBand == nil)
        #expect(l.stripSegments == [l.stripFrame])
        #expect(l.keys.filter { $0.row == 0 }.allSatisfy { if case .symbol = $0.identity { true } else { false } })
        #expect(l.keys.filter { $0.row == 0 }.count == 10)
        let sp = splitLayout(.letters, size: CGSize(width: 951, height: 230))
        #expect(l.metrics.keyWidth > LayoutMetrics.duoInnerMaxKeyWidth)
        #expect(l.metrics.keyHeight > sp.metrics.keyHeight, "bigger keys than the default inner landscape")
        // Same key set as the standard letters layer with number row.
        var plain = LayoutSettings.defaults(for: innerLandscape); plain.splitLandscape = false; plain.numberRow = true
        let std = LayoutEngine.layout(containerSize: Self.size, traits: innerLandscape, kind: .letters, settings: plain)
        #expect(l.keys.map(\.identity) == std.keys.map(\.identity))
    }

    @Test("reserved arrow/edit column sits right of the keys, outside the key area, inside the container")
    func auxColumn() {
        for kind in [LayoutKind.letters, .numbers, .symbols] {
            let l = fold(kind)
            let aux = try! #require(l.auxiliaryColumn)
            #expect(aux.minX >= l.keyArea.maxX - 1e-9 && aux.maxX <= Self.size.width + 1e-9 && aux.width >= 80)
            for k in l.keys { #expect(k.frame.maxX <= aux.minX + 1e-9 && k.frame.maxY <= Self.size.height) }
            #expect(l.hit(at: CGPoint(x: aux.midX, y: aux.midY)) == nil, "column is not part of the key hit model")
            for k in l.keys { #expect(k.touchRegion.maxX <= l.keyArea.maxX + 1e-9) }
        }
        #expect(fold(.numberPad).auxiliaryColumn == nil)
    }

    @Test("fillToFold wins over split and is ignored in portrait and on other displays")
    func gating() {
        var s = LayoutSettings.defaults(for: innerLandscape); s.fillToFold = true
        #expect(s.splitLandscape)
        let l = LayoutEngine.layout(containerSize: Self.size, traits: innerLandscape, kind: .letters, settings: s)
        #expect(l.metrics.mode == .fillToFold)
        let portrait = LayoutEngine.layout(containerSize: CGSize(width: 669, height: 300), traits: innerPortrait, kind: .letters, settings: s)
        #expect(portrait.metrics.mode == .standard && portrait.auxiliaryColumn == nil)
        let phone = LayoutEngine.layout(containerSize: Self.size, traits: LayoutTraits(orientation: .landscape), kind: .letters, settings: s)
        #expect(phone.metrics.mode == .standard)
    }
}

@Suite("Landscape side columns (F13)")
struct LandscapeSideColumnTests {
    private func letters(width: CGFloat, safe: LayoutInsets, orientation: LayoutOrientation = .landscape,
                          settings: LayoutSettings = LayoutSettings()) -> KeyboardLayout {
        let t = LayoutTraits(orientation: orientation)
        let h = LayoutEngine.preferredHeight(width: width, safeArea: safe, traits: t, kind: .letters, settings: settings)
        return LayoutEngine.layout(containerSize: CGSize(width: width, height: h), safeArea: safe, traits: t, kind: .letters, settings: settings)
    }

    @Test("wide phone landscape gets punctuation columns on both sides, standard keys keep their order")
    func columns() {
        for (w, safe) in [(812.0, LayoutInsets(left: 44, bottom: 21, right: 44)), (844, LayoutInsets(left: 47, bottom: 21, right: 47)),
                          (932, LayoutInsets(left: 59, bottom: 21, right: 59))] {
            let l = letters(width: w, safe: safe)
            let plain = letters(width: w, safe: safe, settings: LayoutSettings(landscapeSideKeys: false))
            #expect(l.metrics.sideColumnWidth > 0)
            #expect(l.keys.count == plain.keys.count + 6)
            #expect(Array(l.keys.prefix(plain.keys.count)).map(\.identity) == plain.keys.map(\.identity))
            let side = l.keys.suffix(6)
            #expect(side.allSatisfy { if case .symbol = $0.identity { true } else { false } })
            // Side keys flank the main block symmetrically and are as tall as letter keys.
            let q = l.firstKey(.letter("q"))!, p = l.firstKey(.letter("p"))!
            #expect(side.map { $0.frame.minX }.min()! < q.frame.minX && side.map { $0.frame.maxX }.max()! > p.frame.maxX)
            #expect(abs((q.frame.minX - l.keys.last!.frame.maxX) - (l.keys[l.keys.count - 2].frame.minX - p.frame.maxX)) < 6)
            #expect(l.keys.last!.frame.maxX <= w - safe.right + 0.001)
            // Wider than the old landscape layout would give 10 letter keys? Main block is narrower, keys remain >= 44 pt.
            #expect(q.frame.width >= 44)
        }
    }

    @Test("no columns on narrow landscape, portrait, or when switched off")
    func off() {
        #expect(letters(width: 568, safe: .zero).metrics.sideColumnWidth == 0)
        #expect(letters(width: 390, safe: .zero, orientation: .portrait).metrics.sideColumnWidth == 0)
        #expect(letters(width: 844, safe: .zero, settings: LayoutSettings(landscapeSideKeys: false)).metrics.sideColumnWidth == 0)
    }

    @Test("every point resolves to a key across the side columns")
    func hits() {
        let l = letters(width: 844, safe: LayoutInsets(left: 47, bottom: 21, right: 47))
        for x in stride(from: CGFloat(0), through: 844, by: 7) {
            for y in stride(from: l.keyArea.minY, through: l.bounds.maxY, by: 5) {
                #expect(l.nearestHit(to: CGPoint(x: x, y: y)) != nil)
            }
        }
    }
}
