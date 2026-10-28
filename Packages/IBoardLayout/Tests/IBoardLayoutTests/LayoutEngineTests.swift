import CoreGraphics
import Foundation
import Testing
@testable import IBoardLayout

// MARK: - Test cases (raw sizes, no device models)

struct SizeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let width: CGFloat
    let traits: LayoutTraits
    let safeArea: LayoutInsets

    var testDescription: String { name }

    var settings: LayoutSettings { LayoutSettings.defaults(for: traits) }

    func height(kind: LayoutKind) -> CGFloat {
        // Round to 0.5 pt so snapshots are stable and readable.
        let h = LayoutEngine.preferredHeight(
            width: width, safeArea: safeArea, traits: traits, kind: kind, settings: settings
        )
        return (h * 2).rounded() / 2
    }

    func layout(_ kind: LayoutKind) -> KeyboardLayout {
        LayoutEngine.layout(
            containerSize: CGSize(width: width, height: height(kind: kind)),
            safeArea: safeArea, traits: traits, kind: kind, settings: settings
        )
    }
}

let sizeCases: [SizeCase] = [
    SizeCase(name: "w375-portrait", width: 375, traits: LayoutTraits(), safeArea: .zero),
    SizeCase(name: "w390-portrait", width: 390, traits: LayoutTraits(), safeArea: .zero),
    SizeCase(name: "w428-portrait", width: 428, traits: LayoutTraits(), safeArea: .zero),
    SizeCase(name: "w440-portrait", width: 440, traits: LayoutTraits(), safeArea: .zero),
    SizeCase(name: "w466-duoOuter-portrait", width: 466, traits: LayoutTraits(displayClass: .duoOuter), safeArea: .zero),
    SizeCase(name: "w669-duoInner-portrait", width: 669, traits: LayoutTraits(displayClass: .duoInner), safeArea: .zero),
    SizeCase(
        name: "w844-landscape", width: 844, traits: LayoutTraits(orientation: .landscape),
        safeArea: LayoutInsets(left: 47, bottom: 21, right: 47)
    ),
    SizeCase(
        name: "w932-landscape", width: 932, traits: LayoutTraits(orientation: .landscape),
        safeArea: LayoutInsets(left: 59, bottom: 21, right: 59)
    ),
    SizeCase(
        name: "w667-landscape-se", width: 667, traits: LayoutTraits(orientation: .landscape),
        safeArea: .zero
    ),
    SizeCase(
        name: "w812-landscape", width: 812, traits: LayoutTraits(orientation: .landscape),
        safeArea: LayoutInsets(left: 44, bottom: 21, right: 44)
    ),
    SizeCase(
        name: "w678-duoOuter-landscape", width: 678,
        traits: LayoutTraits(displayClass: .duoOuter, orientation: .landscape), safeArea: .zero
    ),
    SizeCase(
        name: "w951-duoInner-landscape", width: 951,
        traits: LayoutTraits(displayClass: .duoInner, orientation: .landscape), safeArea: .zero
    ),
]

// MARK: - Geometry invariants

@Suite("Layout invariants")
struct LayoutInvariantTests {
    @Test("keys never overlap, stay in bounds and below the strip", arguments: sizeCases, LayoutKind.allCases)
    func geometry(sc: SizeCase, kind: LayoutKind) {
        let l = sc.layout(kind)
        let safe = sc.safeArea
        let inner = CGRect(
            x: safe.left, y: l.stripFrame.maxY,
            width: l.bounds.width - safe.left - safe.right, height: l.bounds.maxY - l.stripFrame.maxY
        )
        let eps: CGFloat = 1e-6
        for k in l.keys {
            #expect(k.frame.minX >= inner.minX - eps && k.frame.maxX <= inner.maxX + eps, "\(k.identity) x out of bounds")
            #expect(k.frame.minY >= inner.minY - eps && k.frame.maxY <= inner.maxY + eps, "\(k.identity) y out of bounds")
            #expect(k.frame.width > 0 && k.frame.height > 0)
        }
        for i in 0..<l.keys.count {
            for j in (i + 1)..<max(l.keys.count, i + 1) {
                let inter = l.keys[i].frame.intersection(l.keys[j].frame)
                #expect(inter.isNull || inter.width * inter.height < eps, "\(l.keys[i].identity) overlaps \(l.keys[j].identity)")
            }
        }
        // Content never intrudes into the Duo fold band's future seam: here simply horizontally symmetric margins.
        let minX = l.keys.map(\.frame.minX).min()!
        let maxX = l.keys.map(\.frame.maxX).max()!
        #expect(abs((minX - inner.minX) - (inner.maxX - maxX)) < 0.5, "left/right margins differ")
    }

    @Test("touch regions tile the key area without holes or overlaps", arguments: sizeCases, LayoutKind.allCases)
    func tiling(sc: SizeCase, kind: LayoutKind) {
        let l = sc.layout(kind)
        let area = l.keyArea
        var sum: CGFloat = 0
        for k in l.keys {
            sum += k.touchRegion.width * k.touchRegion.height
            #expect(k.touchRegion.contains(CGPoint(x: k.frame.midX, y: k.frame.midY)))
            #expect(k.touchRegion.insetBy(dx: -1e-6, dy: -1e-6).contains(k.frame), "region must contain its cap")
            #expect(area.insetBy(dx: -1e-6, dy: -1e-6).contains(k.touchRegion))
        }
        #expect(abs(sum - area.width * area.height) < 1e-3, "region areas must sum to the key area")
        for i in 0..<l.keys.count {
            for j in (i + 1)..<max(l.keys.count, i + 1) {
                let inter = l.keys[i].touchRegion.intersection(l.keys[j].touchRegion)
                #expect(inter.isNull || inter.width * inter.height < 1e-6)
            }
        }
        // Dense point sweep: every point resolves, and to a key whose region contains it.
        var x = area.minX
        while x <= area.maxX {
            var y = area.minY
            while y <= area.maxY {
                let p = CGPoint(x: x, y: y)
                guard let h = l.hit(at: p) else { Issue.record("hole at \(p)"); return }
                if !l.keys[h.keyIndex].touchRegion.insetBy(dx: -1e-6, dy: -1e-6).contains(p) {
                    Issue.record("point \(p) resolved to a key whose region does not contain it"); return
                }
                y += 1.7
            }
            x += 1.7
        }
        #expect(l.hit(at: CGPoint(x: area.midX, y: l.stripFrame.midY)) == nil, "strip is not a key")
        #expect(l.nearestHit(to: CGPoint(x: -50, y: -50)) != nil)
        #expect(l.nearestHit(to: CGPoint(x: -50, y: -50))?.isInsideKeyArea == false)
    }

    @Test("gap points go to the nearer key and normalized offsets are centre relative")
    func gapSplit() {
        let l = SizeCase(name: "x", width: 390, traits: LayoutTraits(), safeArea: .zero).layout(.letters)
        let q = l.firstKey(.letter("q"))!, w = l.firstKey(.letter("w"))!
        let mid = (q.frame.maxX + w.frame.minX) / 2
        let y = q.frame.midY
        #expect(l.key(at: CGPoint(x: mid - 0.1, y: y))?.identity == .letter("q"))
        #expect(l.key(at: CGPoint(x: mid + 0.1, y: y))?.identity == .letter("w"))
        // Left of Q (edge margin) still resolves to Q; below the last row resolves to the bottom row.
        #expect(l.key(at: CGPoint(x: 0, y: y))?.identity == .letter("q"))
        #expect(l.key(at: CGPoint(x: 195, y: l.bounds.maxY))?.identity == .space)
        let h = l.hit(at: CGPoint(x: q.frame.midX, y: q.frame.midY))!
        #expect(abs(h.normalized.x) < 1e-9 && abs(h.normalized.y) < 1e-9)
        let edge = l.hit(at: CGPoint(x: q.frame.maxX, y: q.frame.midY))!
        #expect(abs(edge.normalized.x - 0.5) < 1e-9)
        // Same relative tap on two sizes gives the same normalized offset (resize invariance for F14).
        let big = LayoutEngine.layout(
            containerSize: CGSize(width: 390, height: 312), traits: LayoutTraits(), kind: .letters
        )
        let qb = big.firstKey(.letter("q"))!
        let p = CGPoint(x: q.frame.minX + q.frame.width * 0.8, y: q.frame.minY + q.frame.height * 0.3)
        let pb = CGPoint(x: qb.frame.minX + qb.frame.width * 0.8, y: qb.frame.minY + qb.frame.height * 0.3)
        let a = l.hit(at: p)!.normalized, b = big.hit(at: pb)!.normalized
        #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9)
    }

    @Test("centre gap is ignored unless the split is active (see DuoLayoutTests for the split)")
    func centreGapIgnoredWithoutSplit() {
        let size = CGSize(width: 951, height: 206)
        let traits = LayoutTraits(displayClass: .duoInner, orientation: .landscape)
        let plain = LayoutEngine.layout(containerSize: size, traits: traits, kind: .letters)
        let gap = LayoutEngine.layout(
            containerSize: size, traits: traits, kind: .letters,
            settings: LayoutSettings(centreGap: CentreGap(centerX: 475.5, width: 27))
        )
        #expect(plain == gap)
    }

    @Test("preferred height: 390 portrait is the 270 default and heightScale scales the body")
    func preferredHeight() {
        let t = LayoutTraits()
        #expect(LayoutEngine.preferredHeight(width: 390, traits: t, kind: .letters) == 270)
        #expect(LayoutEngine.preferredHeight(width: 390, traits: t, kind: .numberPad) == 270)
        let big = LayoutEngine.preferredHeight(width: 390, traits: t, kind: .letters, settings: LayoutSettings(heightScale: 1.4))
        #expect(abs(big - (44 + 226 * 1.4)) < 1e-9)
        let withNumberRow = LayoutEngine.preferredHeight(width: 390, traits: t, kind: .letters, settings: LayoutSettings(numberRow: true))
        #expect(abs(withNumberRow - 314) < 1e-9)
    }
}

// MARK: - Key sets per trait

@Suite("Trait variants")
struct TraitVariantTests {
    func names(_ l: KeyboardLayout) -> [String] { l.keys.map(\.identity.snapshotName) }

    func layout(
        _ kind: LayoutKind = .letters, traits: LayoutTraits = LayoutTraits(), settings: LayoutSettings = LayoutSettings(),
        width: CGFloat = 390
    ) -> KeyboardLayout {
        LayoutEngine.layout(
            containerSize: CGSize(
                width: width,
                height: LayoutEngine.preferredHeight(width: width, traits: traits, kind: kind, settings: settings)
            ),
            traits: traits, kind: kind, settings: settings
        )
    }

    @Test func defaultLetters() {
        let l = layout()
        #expect(l.keys.count == 26 + 5) // letters, shift, delete, 123, space, return
        let letters = l.keys.compactMap { k -> String? in if case .letter(let s) = k.identity { s } else { nil } }
        #expect(letters.sorted() == "abcdefghijklmnopqrstuvwxyz".map(String.init))
        #expect(l.keys.filter { $0.row == 0 }.count == 10)
        #expect(l.keys.filter { $0.row == 1 }.count == 9)
        #expect(names(l).contains("layer:numbers"))
        #expect(!names(l).contains("globe"))
        #expect(l.firstKey(.returnKey(.default)) != nil)
    }

    @Test func globeOnlyWhenSystemAsks() {
        let off = layout(traits: LayoutTraits(needsInputModeSwitchKey: false))
        let on = layout(traits: LayoutTraits(needsInputModeSwitchKey: true))
        #expect(off.firstKey(.globe) == nil)
        let globe = on.firstKey(.globe)
        #expect(globe != nil)
        let toggle = on.firstKey(.layerSwitch(.numbers))!
        #expect(globe!.frame.minX > toggle.frame.maxX)
        // Space is unchanged by the globe (it shares the 123 key's width).
        #expect(abs(on.firstKey(.space)!.frame.width - off.firstKey(.space)!.frame.width) < 1e-9)
        for kind in [LayoutKind.numbers, .symbols] {
            #expect(layout(kind, traits: LayoutTraits(needsInputModeSwitchKey: true)).firstKey(.globe) != nil)
            #expect(layout(kind).firstKey(.globe) == nil)
        }
        // Pads never get a globe from the engine (the system draws it).
        #expect(layout(.numberPad, traits: LayoutTraits(needsInputModeSwitchKey: true)).firstKey(.globe) == nil)
    }

    @Test func emojiKeySitsNextTo123AndSharesItsWidth() {
        let plain = layout()
        #expect(plain.firstKey(.emoji) == nil)
        let on = layout(settings: LayoutSettings(emojiKey: true))
        let toggle = on.firstKey(.layerSwitch(.numbers))!, emoji = on.firstKey(.emoji)!
        #expect(emoji.frame.minX > toggle.frame.maxX)
        #expect(emoji.frame.maxX <= on.firstKey(.space)!.frame.minX)
        let full = plain.firstKey(.layerSwitch(.numbers))!.frame.width
        #expect(abs((toggle.frame.width + emoji.frame.width) - full) < 8) // the pair takes the old 123 key's room
        #expect(abs(on.firstKey(.space)!.frame.width - plain.firstKey(.space)!.frame.width) < 1e-9)
        // With the system globe too: three keys share the same room, in order 123, globe, emoji.
        let three = layout(traits: LayoutTraits(needsInputModeSwitchKey: true), settings: LayoutSettings(emojiKey: true))
        let xs = [three.firstKey(.layerSwitch(.numbers))!, three.firstKey(.globe)!, three.firstKey(.emoji)!].map(\.frame.minX)
        #expect(xs == xs.sorted())
        for kind in [LayoutKind.numbers, .symbols] {
            #expect(layout(kind, settings: LayoutSettings(emojiKey: true)).firstKey(.emoji) != nil)
        }
        #expect(layout(.numberPad, settings: LayoutSettings(emojiKey: true)).firstKey(.emoji) == nil)
    }

    @Test func commaAndEmojiAreOneKeyAndTheSpaceBarGrows() {
        let separate = layout(settings: LayoutSettings(punctuationKeys: true))
        let merged = layout(settings: LayoutSettings(punctuationKeys: true, emojiKey: true))
        #expect(merged.firstKey(.commaEmoji) != nil)
        #expect(merged.firstKey(.emoji) == nil)
        #expect(merged.firstKey(.symbol(",")) == nil) // no separate comma key
        #expect(merged.firstKey(.symbol(".")) != nil)
        let c = merged.firstKey(.commaEmoji)!, toggle = merged.firstKey(.layerSwitch(.numbers))!, space = merged.firstKey(.space)!
        #expect(c.frame.minX > toggle.frame.maxX && c.frame.maxX <= space.frame.minX)
        #expect(space.frame.width > separate.firstKey(.space)!.frame.width + merged.metrics.tailKeyWidth - 1)
        // Globe too: 123, globe, comma/emoji in order.
        let g = layout(traits: LayoutTraits(needsInputModeSwitchKey: true), settings: LayoutSettings(punctuationKeys: true, emojiKey: true))
        let xs = [g.firstKey(.layerSwitch(.numbers))!, g.firstKey(.globe)!, g.firstKey(.commaEmoji)!].map(\.frame.minX)
        #expect(xs == xs.sorted())
        // Emoji key off: a plain comma key, as before. Punctuation off: the plain emoji key.
        #expect(layout(settings: LayoutSettings(punctuationKeys: true)).firstKey(.symbol(",")) != nil)
        let noPunct = layout(settings: LayoutSettings(emojiKey: true))
        #expect(noPunct.firstKey(.emoji) != nil && noPunct.firstKey(.commaEmoji) == nil)
        // Number layers keep the emoji key; URL / email keyboards keep it too (no comma key there).
        #expect(layout(.numbers, settings: LayoutSettings(punctuationKeys: true, emojiKey: true)).firstKey(.emoji) != nil)
        for kb in [KeyboardKind.url, .emailAddress] {
            let l = layout(traits: LayoutTraits(keyboardKind: kb), settings: LayoutSettings(punctuationKeys: true, emojiKey: true))
            #expect(l.firstKey(.emoji) != nil && l.firstKey(.commaEmoji) == nil)
        }
    }

    @Test func compactChromeGivesBiggerKeysAndAShorterStrip() {
        let plain = layout(), tight = layout(settings: LayoutSettings(compact: true))
        #expect(tight.stripFrame.height < plain.stripFrame.height)
        let a = plain.firstKey(.letter("a"))!.frame, b = tight.firstKey(.letter("a"))!.frame
        #expect(b.width > a.width && b.height > a.height)
        #expect(tight.keys.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 390 })
        let (q, w) = (tight.firstKey(.letter("q"))!.frame, tight.firstKey(.letter("w"))!.frame)
        #expect(w.minX - q.maxX < 5)
    }

    @Test func email() {
        let l = layout(traits: LayoutTraits(keyboardKind: .emailAddress))
        let bottom = l.keys.filter { $0.row == 3 }.map(\.identity)
        #expect(bottom == [.layerSwitch(.numbers), .space, .symbol("@"), .symbol("."), .returnKey(.default)])
        #expect(l.keys.count == 26 + 7)
    }

    @Test func url() {
        let l = layout(traits: LayoutTraits(keyboardKind: .url))
        let bottom = l.keys.filter { $0.row == 3 }.map(\.identity)
        #expect(bottom == [.layerSwitch(.numbers), .symbol("."), .symbol("/"), .domainSuffix(".com"), .returnKey(.default)])
        #expect(l.firstKey(.space) == nil)
    }

    @Test func emailAndURLOnlyAffectLetters() {
        let t = LayoutTraits(keyboardKind: .emailAddress)
        #expect(layout(.numbers, traits: t).firstKey(.space) != nil)
        #expect(layout(.numbers, traits: t).firstKey(.symbol("@")) != nil) // the normal @ on the 123 layer
    }

    @Test func returnKeyKinds() {
        for r in ReturnKeyKind.allCases {
            let l = layout(traits: LayoutTraits(returnKey: r))
            #expect(l.firstKey(.returnKey(r)) != nil)
        }
    }

    @Test func numberRow() {
        let base = layout()
        let withRow = layout(settings: LayoutSettings(numberRow: true), width: 390)
        #expect(withRow.keys.count == base.keys.count + 10)
        #expect(withRow.keys.filter { $0.row == 0 }.map(\.identity) == "1234567890".map { .symbol(String($0)) })
        #expect(withRow.firstKey(.letter("q"))!.row == 1)
        // The row only exists on the letters layer.
        #expect(layout(.numbers, settings: LayoutSettings(numberRow: true)).keys.count == layout(.numbers).keys.count)
        // Duo inner portrait turns it on by default (F1/F18).
        let duo = LayoutTraits(displayClass: .duoInner)
        #expect(LayoutSettings.defaults(for: duo).numberRow)
        #expect(!LayoutSettings.defaults(for: LayoutTraits()).numberRow)
        #expect(!LayoutSettings.defaults(for: LayoutTraits(displayClass: .duoInner, orientation: .landscape)).numberRow)
    }

    @Test func punctuationKeys() {
        let l = layout(settings: LayoutSettings(punctuationKeys: true))
        let bottom = l.keys.filter { $0.row == 3 }.map(\.identity)
        #expect(bottom == [.layerSwitch(.numbers), .symbol(","), .space, .symbol("."), .returnKey(.default)])
        // Email/URL keep their own keys.
        let email = layout(traits: LayoutTraits(keyboardKind: .emailAddress), settings: LayoutSettings(punctuationKeys: true))
        #expect(!email.keys.contains { $0.identity == .symbol(",") })
    }

    @Test func searchReturnKeyShrinksToAnIconAndGivesTheSpaceBarRoom() {
        func widths(_ kind: ReturnKeyKind, punctuation: Bool) -> (ret: CGFloat, space: CGFloat) {
            let l = layout(traits: LayoutTraits(returnKey: kind), settings: LayoutSettings(punctuationKeys: punctuation))
            return (l.firstKey(.returnKey(kind))!.frame.width, l.firstKey(.space)!.frame.width)
        }
        let icon = widths(.search, punctuation: true), plain = widths(.emergencyCall, punctuation: true) // the one text key left
        #expect(icon.ret < plain.ret * 0.7 && icon.space > plain.space)
        // "return", "next" and "done" are icons too (a wide text key took the space bar's room); without the comma/period
        // keys every return key keeps its native text label and width.
        #expect(widths(.default, punctuation: true).ret == icon.ret)
        #expect(widths(.search, punctuation: false).ret == widths(.default, punctuation: false).ret)
        #expect(ReturnKeyKind.search.iconSymbol == "magnifyingglass" && ReturnKeyKind.default.iconSymbol == "return"
                && ReturnKeyKind.done.iconSymbol == "checkmark" && ReturnKeyKind.emergencyCall.iconSymbol == nil)
    }

    @Test func searchRowGrowsTheStripAndKeepsTheKeySizes() {
        let base = LayoutSettings(compact: true)
        var withRow = base; withRow.searchRowHeight = 44
        let t = LayoutTraits()
        let h0 = LayoutEngine.preferredHeight(width: 390, safeArea: .zero, traits: t, kind: .letters, settings: base)
        let h1 = LayoutEngine.preferredHeight(width: 390, safeArea: .zero, traits: t, kind: .letters, settings: withRow)
        #expect(abs((h1 - h0) - 44) < 0.01)
        let a = LayoutEngine.layout(containerSize: CGSize(width: 390, height: h0), safeArea: .zero, traits: t, kind: .letters, settings: base)
        let b = LayoutEngine.layout(containerSize: CGSize(width: 390, height: h1), safeArea: .zero, traits: t, kind: .letters, settings: withRow)
        #expect(abs(b.stripFrame.height - a.stripFrame.height - 44) < 0.01)
        let qa = a.firstKey(.letter("q"))!.frame, qb = b.firstKey(.letter("q"))!.frame
        #expect(abs(qa.height - qb.height) < 0.01 && abs(qb.minY - qa.minY - 44) < 0.01)
    }

    @Test func numbersAndSymbols() {
        let n = layout(.numbers, settings: LayoutSettings(currency: .inr))
        #expect(n.keys.count == 10 + 10 + 7 + 3)
        #expect(n.firstKey(.layerSwitch(.symbols)) != nil)
        #expect(n.firstKey(.symbol("₹")) != nil && n.firstKey(.symbol("$")) == nil)
        let s = layout(.symbols)
        #expect(s.keys.count == 10 + 10 + 7 + 3)
        #expect(s.firstKey(.layerSwitch(.numbers)) != nil)
        #expect(["€", "£", "¥", "•"].allSatisfy { s.firstKey(.symbol($0)) != nil })
        #expect(layout(.numbers).firstKey(.layerSwitch(.letters)) != nil)
        #expect(s.firstKey(.layerSwitch(.letters)) != nil)
    }

    @Test func pads() {
        let num = layout(.numberPad)
        #expect(num.keys.count == 11) // 1-9, 0, delete
        let dec = layout(.decimalPad)
        #expect(dec.keys.count == 12 && dec.firstKey(.symbol(".")) != nil)
        let tel = layout(.phonePad)
        #expect(tel.keys.count == 12 && tel.firstKey(.symbol("+*#")) != nil)
        for l in [num, dec, tel] {
            #expect(l.firstKey(.delete) != nil && l.firstKey(.space) == nil && l.firstKey(.returnKey(.default)) == nil)
        }
        #expect(LayoutKind.initial(for: .numberPad) == .numberPad)
        #expect(LayoutKind.initial(for: .decimalPad) == .decimalPad)
        #expect(LayoutKind.initial(for: .phonePad) == .phonePad)
        #expect(LayoutKind.initial(for: .emailAddress) == .letters)
    }

    @Test func orientationAndDisplayDoNotChangeKeySets() {
        let ref = Set(names(layout()))
        // F13: phone landscape adds punctuation columns (nothing else changes).
        let sideSymbols = Set(["\"", "'", "!", "?", "-", ";", ":", "/"].map { "symbol:\($0)" })
        for sc in sizeCases {
            #expect(Set(sc.layout(.letters).keys.map(\.identity.snapshotName)).subtracting(ref).subtracting(
                (0...9).map { "symbol:\($0)" }).subtracting(sideSymbols).isEmpty)
        }
        let landscape = layout(traits: LayoutTraits(orientation: .landscape), width: 844)
        #expect(Set(names(landscape)).subtracting(sideSymbols) == ref.subtracting(sideSymbols))
        #expect(Set(names(landscape)).isSuperset(of: ref))
    }

    @Test func duoInnerCapsKeyWidth() {
        let l = layout(traits: LayoutTraits(displayClass: .duoInner), width: 669)
        #expect(l.metrics.keyWidth <= 56 + 1e-9)
        #expect(l.metrics.contentLeft > 20, "capped block is centred")
        // Hit regions still reach both container edges.
        #expect(l.key(at: CGPoint(x: 0, y: l.firstKey(.letter("q"))!.frame.midY))?.identity == .letter("q"))
    }
}
