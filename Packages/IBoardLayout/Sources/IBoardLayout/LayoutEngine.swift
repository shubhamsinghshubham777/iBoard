import CoreGraphics

/// The computed layout: key frames, identities, touch regions and the hit model for one container + layer.
public struct KeyboardLayout: Sendable, Equatable {
    public let kind: LayoutKind
    public let traits: LayoutTraits
    public let bounds: CGRect
    /// Frame of the suggestion strip (not a key; touches there are not resolved by the hit model).
    public let stripFrame: CGRect
    /// Suggestion strip pieces: one (== `stripFrame`) normally, two around the fold in split mode. Strip controls
    /// must live inside these, never in `foldBand`.
    public let stripSegments: [CGRect]
    /// Full-height band no key cap or strip control enters (split mode only; touch regions still cross it).
    public let foldBand: CGRect?
    /// Laptop "fill to fold": frame reserved for the arrow/edit column (keys for it are not defined yet).
    public let auxiliaryColumn: CGRect?
    /// Area the key touch regions tile: `bounds` below the strip (minus the auxiliary column in fill-to-fold mode).
    public let keyArea: CGRect
    public let keys: [KeyboardKey]
    public let metrics: LayoutMetrics
    public let hitModel: HitModel

    /// Strict hit test: nil outside the key area.
    public func hit(at point: CGPoint) -> KeyHit? {
        guard let i = hitModel.keyIndex(at: point) else { return nil }
        return KeyHit(keyIndex: i, normalized: keys[i].normalizedOffset(of: point), isInsideKeyArea: true)
    }

    /// Nearest-key hit test; a point outside the key area is clamped to it first.
    public func nearestHit(to point: CGPoint) -> KeyHit? {
        guard let i = hitModel.nearestKeyIndex(to: point) else { return nil }
        return KeyHit(
            keyIndex: i,
            normalized: keys[i].normalizedOffset(of: point),
            isInsideKeyArea: keyArea.contains(point)
        )
    }

    public func key(at point: CGPoint) -> KeyboardKey? {
        hit(at: point).map { keys[$0.keyIndex] }
    }

    public func firstKey(_ identity: KeyIdentity) -> KeyboardKey? {
        keys.first { $0.identity == identity }
    }
}

/// Pure layout function. No UIKit, no global state, no device model lookups.
public enum LayoutEngine {
    /// Compute the layout that fills `containerSize`.
    ///
    /// - Parameters:
    ///   - containerSize: size of the keyboard view (strip included).
    ///   - safeArea: left/right insets keep keys out of the notch area; bottom raises the bottom row.
    ///   - traits: display class, orientation, keyboard type, return key, globe rule.
    ///   - kind: which layer to lay out. Trait variants (email, URL) apply to `.letters`.
    ///   - settings: number row, punctuation keys, currency; `heightScale` only affects `preferredHeight`.
    public static func layout(
        containerSize: CGSize,
        safeArea: LayoutInsets = .zero,
        traits: LayoutTraits,
        kind: LayoutKind,
        settings: LayoutSettings = LayoutSettings()
    ) -> KeyboardLayout {
        let m = LayoutMetrics.resolve(
            containerSize: containerSize, safeArea: safeArea, traits: traits, kind: kind, settings: settings
        )
        let settings = LayoutMetrics.effectiveSettings(settings, mode: m.mode)
        let bounds = CGRect(origin: .zero, size: containerSize)
        let strip = CGRect(x: 0, y: 0, width: containerSize.width, height: m.stripHeight)
        var keyAreaWidth = containerSize.width
        var aux: CGRect?
        if m.mode == .fillToFold {
            keyAreaWidth = m.auxColumnMinX
            aux = CGRect(
                x: m.auxColumnMinX, y: m.stripHeight + m.topGap, width: m.auxColumnWidth,
                height: max(containerSize.height - m.bottomInset - m.stripHeight - m.topGap, 0)
            )
        }
        let keyArea = CGRect(
            x: 0, y: m.stripHeight, width: keyAreaWidth,
            height: max(containerSize.height - m.stripHeight, 0)
        )
        var band: CGRect?
        var stripSegments = [strip]
        if case .split(let gap) = m.mode {
            let b = CGRect(x: gap.centerX - gap.width / 2, y: 0, width: gap.width, height: containerSize.height)
            band = b
            stripSegments = [
                CGRect(x: 0, y: 0, width: b.minX, height: m.stripHeight),
                CGRect(x: b.maxX, y: 0, width: containerSize.width - b.maxX, height: m.stripHeight),
            ]
        }

        var placer = Placer(metrics: m, firstRowY: m.stripHeight + m.topGap)
        if kind.isPad {
            placer.buildPad(kind: kind, traits: traits)
        } else if case .split = m.mode {
            placer.buildSplit(kind: kind, traits: traits, settings: settings)
        } else {
            placer.buildLetters(kind: kind, traits: traits, settings: settings)
        }

        let (hit, regions) = HitModel.build(
            frames: placer.placed.map(\.frame), rowOfKey: placer.placed.map(\.row), keyArea: keyArea
        )
        let keys = placer.placed.enumerated().map { i, p in
            KeyboardKey(id: i, identity: p.identity, frame: p.frame, touchRegion: regions[i], row: p.row)
        }
        return KeyboardLayout(
            kind: kind, traits: traits, bounds: bounds, stripFrame: strip, stripSegments: stripSegments,
            foldBand: band, auxiliaryColumn: aux, keyArea: keyArea,
            keys: keys, metrics: m, hitModel: hit
        )
    }

    /// Height the host should give the keyboard view for a width, before any user resize.
    ///
    /// Rules (portrait phone at 390 pt gives exactly the measured 260 pt):
    /// body height (everything below the strip) x width growth x display factor x `settings.heightScale`.
    /// - Width growth (phones): 1 + 0.25 x (clamp(width, 390, 440) / 390 - 1), ESTIMATED from the small native
    ///   height increase on larger iPhones.
    /// - Display factor: Duo outer portrait 0.88 ("lower default height ratio", ESTIMATED), everything else 1.
    /// - Laptop "fill to fold" height is not a function of width: the host uses `DuoGeometry.fillToFoldHeight`.
    public static func preferredHeight(
        width: CGFloat,
        safeArea: LayoutInsets = .zero,
        traits: LayoutTraits,
        kind: LayoutKind,
        settings: LayoutSettings = LayoutSettings()
    ) -> CGFloat {
        let ref = LayoutMetrics.reference(kind: kind, orientation: traits.orientation)
        let mode = LayoutMetrics.duoMode(
            containerSize: CGSize(width: width, height: 0), traits: traits, kind: kind, settings: settings
        )
        let body = ref.body(rows: LayoutMetrics.rowCount(
            kind: kind, settings: LayoutMetrics.effectiveSettings(settings, mode: mode)
        ))
        let growth: CGFloat = traits.displayClass == .phone
            ? 1 + 0.25 * (min(max(width, 390), 440) / 390 - 1)
            : 1
        let factor: CGFloat = traits.displayClass == .duoOuter && traits.orientation == .portrait
            ? LayoutMetrics.duoOuterHeightFactorPortrait : 1
        return ref.stripHeight + body * growth * factor * settings.heightScale + safeArea.bottom
    }
}

// MARK: - Row placement

private struct Placed {
    var identity: KeyIdentity
    var frame: CGRect
    var row: Int
}

private struct Placer {
    let m: LayoutMetrics
    let firstRowY: CGFloat
    var placed: [Placed] = []
    private var rowCount = 0

    init(metrics: LayoutMetrics, firstRowY: CGFloat) {
        self.m = metrics
        self.firstRowY = firstRowY
    }

    private var pitch: CGFloat { m.keyWidth + m.columnGap }
    private var right: CGFloat { m.contentLeft + m.contentWidth }

    private func rowY(_ row: Int) -> CGFloat { firstRowY + CGFloat(row) * (m.keyHeight + m.rowGap) }

    private mutating func add(_ id: KeyIdentity, x: CGFloat, w: CGFloat, row: Int, h: CGFloat? = nil) {
        placed.append(Placed(
            identity: id, frame: CGRect(x: x, y: rowY(row), width: w, height: h ?? m.keyHeight), row: row
        ))
    }

    private mutating func evenRow(_ ids: [KeyIdentity], startX: CGFloat, row: Int) {
        for (i, id) in ids.enumerated() { add(id, x: startX + CGFloat(i) * pitch, w: m.keyWidth, row: row) }
    }

    private static func letters(_ s: String) -> [KeyIdentity] { s.map { .letter(String($0)) } }
    private static func symbols(_ list: [String]) -> [KeyIdentity] { list.map { .symbol($0) } }

    mutating func buildLetters(kind: LayoutKind, traits: LayoutTraits, settings: LayoutSettings) {
        var row = 0
        let cap = m.contentLeft
        let span7 = 7 * m.keyWidth + 6 * m.columnGap
        let thirdStart = m.contentLeft + (m.contentWidth - span7) / 2
        let tenKeys = m.contentLeft

        switch kind {
        case .letters:
            if settings.numberRow {
                evenRow(Self.symbols(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]), startX: tenKeys, row: row)
                row += 1
            }
            evenRow(Self.letters("qwertyuiop"), startX: tenKeys, row: row); row += 1
            evenRow(Self.letters("asdfghjkl"), startX: m.contentLeft + pitch / 2, row: row); row += 1
            add(.shift, x: cap, w: m.functionKeyWidth, row: row)
            evenRow(Self.letters("zxcvbnm"), startX: thirdStart, row: row)
            add(.delete, x: right - m.functionKeyWidth, w: m.functionKeyWidth, row: row)
            row += 1
        case .numbers, .symbols:
            let first: [String]
            let second: [String]
            if kind == .numbers {
                first = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
                second = ["-", "/", ":", ";", "(", ")", settings.currency.primary, "&", "@", "\""]
            } else {
                first = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
                second = ["_", "\\", "|", "~", "<", ">"] + settings.currency.others + ["•"]
            }
            evenRow(Self.symbols(first), startX: tenKeys, row: row); row += 1
            evenRow(Self.symbols(second), startX: tenKeys, row: row); row += 1
            add(.layerSwitch(kind == .numbers ? .symbols : .numbers), x: cap, w: m.functionKeyWidth, row: row)
            let punct = [".", ",", "?", "!", "'"]
            let w = (span7 - 4 * m.columnGap) / 5
            for (i, p) in punct.enumerated() {
                add(.symbol(p), x: thirdStart + CGFloat(i) * (w + m.columnGap), w: w, row: row)
            }
            add(.delete, x: right - m.functionKeyWidth, w: m.functionKeyWidth, row: row)
            row += 1
        default:
            break
        }
        buildBottomRow(kind: kind, traits: traits, settings: settings, row: row)
        rowCount = row + 1
    }

    private mutating func buildBottomRow(kind: LayoutKind, traits: LayoutTraits, settings: LayoutSettings, row: Int) {
        let g = m.columnGap
        let sideW = m.sideKeyWidth
        let toggleTarget: LayoutKind = kind == .letters ? .numbers : .letters

        // Left group: 123/ABC, plus the globe (when the system asks for it) and the emoji key, splitting the same width.
        var leftKeys: [KeyIdentity] = [.layerSwitch(toggleTarget)]
        if traits.needsInputModeSwitchKey { leftKeys.append(.globe) }
        if settings.emojiKey { leftKeys.append(.emoji) }
        let each = (sideW - g * CGFloat(leftKeys.count - 1)) / CGFloat(leftKeys.count)
        for (i, id) in leftKeys.enumerated() { add(id, x: m.contentLeft + CGFloat(i) * (each + g), w: each, row: row) }
        let midLeft = m.contentLeft + sideW + g
        let returnX = right - sideW
        let midRight = returnX - g
        let tail = m.tailKeyWidth

        let isLetters = kind == .letters
        if isLetters && traits.keyboardKind == .url {
            // No space bar on the URL keyboard (measured): . / .com share the middle equally.
            let w = (midRight - midLeft - 2 * g) / 3
            add(.symbol("."), x: midLeft, w: w, row: row)
            add(.symbol("/"), x: midLeft + w + g, w: w, row: row)
            add(.domainSuffix(".com"), x: midLeft + 2 * (w + g), w: w, row: row)
        } else if isLetters && traits.keyboardKind == .emailAddress {
            let spaceW = midRight - midLeft - 2 * (g + tail)
            add(.space, x: midLeft, w: spaceW, row: row)
            add(.symbol("@"), x: midLeft + spaceW + g, w: tail, row: row)
            add(.symbol("."), x: midLeft + spaceW + 2 * g + tail, w: tail, row: row)
        } else if isLetters && settings.punctuationKeys {
            add(.symbol(","), x: midLeft, w: tail, row: row)
            add(.space, x: midLeft + tail + g, w: midRight - midLeft - 2 * (tail + g), row: row)
            add(.symbol("."), x: midRight - tail, w: tail, row: row)
        } else {
            add(.space, x: midLeft, w: midRight - midLeft, row: row)
        }
        add(.returnKey(traits.returnKey), x: returnX, w: sideW, row: row)
    }

    // MARK: Split (Duo inner)

    private struct SItem {
        var id: KeyIdentity
        /// nil = flexible: shares the half's leftover width.
        var width: CGFloat?
    }

    /// Place one row as two halves. `left` / `right` are in reading order; identities are appended left half first,
    /// so the overall key order equals the non-split layout's (the swipe decoder and touch model rely on it).
    private mutating func addSplitRow(left: [SItem], right: [SItem], row: Int) {
        func place(_ items: [SItem], from lo: CGFloat, to hi: CGFloat, hugsHi: Bool) {
            guard !items.isEmpty else { return }
            let g = m.columnGap
            let fixedSum = items.reduce(CGFloat(0)) { $0 + ($1.width ?? 0) }
            let flexCount = items.filter { $0.width == nil }.count
            let gaps = CGFloat(items.count - 1) * g
            let flexW = flexCount > 0 ? max(hi - lo - fixedSum - gaps, 0) / CGFloat(flexCount) : 0
            let total = fixedSum + gaps + flexW * CGFloat(flexCount)
            // A row without flexible keys is aligned to the fold side of its half.
            var x = (flexCount == 0 && hugsHi) ? hi - total : lo
            for it in items {
                let w = it.width ?? flexW
                add(it.id, x: x, w: w, row: row)
                x += w + g
            }
        }
        place(left, from: m.splitLeftMinX, to: m.splitLeftMaxX, hugsHi: true)
        place(right, from: m.splitRightMinX, to: m.splitRightMaxX, hugsHi: false)
    }

    private func fixedKeys(_ ids: [KeyIdentity]) -> [SItem] { ids.map { SItem(id: $0, width: m.keyWidth) } }

    mutating func buildSplit(kind: LayoutKind, traits: LayoutTraits, settings: LayoutSettings) {
        var row = 0
        func flex(_ id: KeyIdentity) -> SItem { SItem(id: id, width: nil) }
        func halves(_ ids: [KeyIdentity], _ n: Int) -> ([SItem], [SItem]) {
            (fixedKeys(Array(ids[0..<n])), fixedKeys(Array(ids[n...])))
        }
        switch kind {
        case .letters:
            if settings.numberRow {
                let (l, r) = halves(Self.symbols(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]), 5)
                addSplitRow(left: l, right: r, row: row); row += 1
            }
            let l1 = Self.letters("qwertyuiop"), l2 = Self.letters("asdfghjkl"), l3 = Self.letters("zxcvbnm")
            let (a1, b1) = halves(l1, 5)
            addSplitRow(left: a1, right: b1, row: row); row += 1
            let (a2, b2) = halves(l2, 5)
            addSplitRow(left: a2, right: b2, row: row); row += 1
            let (a3, b3) = halves(l3, 4)
            addSplitRow(left: [flex(.shift)] + a3, right: b3 + [flex(.delete)], row: row); row += 1
        case .numbers, .symbols:
            let first: [String]
            let second: [String]
            if kind == .numbers {
                first = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
                second = ["-", "/", ":", ";", "(", ")", settings.currency.primary, "&", "@", "\""]
            } else {
                first = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
                second = ["_", "\\", "|", "~", "<", ">"] + settings.currency.others + ["•"]
            }
            let (a1, b1) = halves(Self.symbols(first), 5)
            addSplitRow(left: a1, right: b1, row: row); row += 1
            let (a2, b2) = halves(Self.symbols(second), 5)
            addSplitRow(left: a2, right: b2, row: row); row += 1
            let (a3, b3) = halves(Self.symbols([".", ",", "?", "!", "'"]), 3)
            addSplitRow(
                left: [flex(.layerSwitch(kind == .numbers ? .symbols : .numbers))] + a3,
                right: b3 + [flex(.delete)], row: row
            ); row += 1
        default:
            break
        }
        buildSplitBottomRow(kind: kind, traits: traits, settings: settings, row: row)
        rowCount = row + 1
    }

    /// Bottom row split. ESTIMATED arrangement: there is exactly one space key (identity unchanged), kept in the
    /// left half; return takes the right half. 123 and globe are function-key width.
    private mutating func buildSplitBottomRow(kind: LayoutKind, traits: LayoutTraits, settings: LayoutSettings, row: Int) {
        let toggleTarget: LayoutKind = kind == .letters ? .numbers : .letters
        let fw = m.functionKeyWidth
        var left = [SItem(id: .layerSwitch(toggleTarget), width: fw)]
        if traits.needsInputModeSwitchKey { left.append(SItem(id: .globe, width: fw)) }
        if settings.emojiKey { left.append(SItem(id: .emoji, width: fw)) }
        var right: [SItem] = []
        let ret = SItem(id: .returnKey(traits.returnKey), width: nil)
        let isLetters = kind == .letters
        if isLetters && traits.keyboardKind == .url {
            left += [SItem(id: .symbol("."), width: nil), SItem(id: .symbol("/"), width: nil)]
            right = [SItem(id: .domainSuffix(".com"), width: nil), ret]
        } else if isLetters && traits.keyboardKind == .emailAddress {
            left.append(SItem(id: .space, width: nil))
            right = [SItem(id: .symbol("@"), width: m.tailKeyWidth), SItem(id: .symbol("."), width: m.tailKeyWidth), ret]
        } else if isLetters && settings.punctuationKeys {
            left += [SItem(id: .symbol(","), width: m.tailKeyWidth), SItem(id: .space, width: nil)]
            right = [SItem(id: .symbol("."), width: m.tailKeyWidth), ret]
        } else {
            left.append(SItem(id: .space, width: nil))
            right = [ret]
        }
        addSplitRow(left: left, right: right, row: row)
    }

    mutating func buildPad(kind: LayoutKind, traits: LayoutTraits) {
        let w = m.padKeyWidth
        let pitchX = w + m.columnGap
        for r in 0..<3 {
            for c in 0..<3 {
                add(.symbol(String(r * 3 + c + 1)), x: m.padContentLeft + CGFloat(c) * pitchX, w: w, row: r)
            }
        }
        switch kind {
        case .decimalPad: add(.symbol("."), x: m.padContentLeft, w: w, row: 3)
        case .phonePad: add(.symbol("+*#"), x: m.padContentLeft, w: w, row: 3)
        default: break
        }
        add(.symbol("0"), x: m.padContentLeft + pitchX, w: w, row: 3)
        add(.delete, x: m.padContentLeft + 2 * pitchX, w: w, row: 3)
        rowCount = 4
    }
}
