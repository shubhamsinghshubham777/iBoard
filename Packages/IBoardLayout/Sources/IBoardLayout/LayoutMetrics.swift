import CoreGraphics

/// Resolved design tokens for one layout, in points. Derived from the container size by documented rules
/// (docs/LAYOUT_ENGINE.md); the reference values are the measured iPhone 12 "Native" numbers from
/// docs/reference/native-metrics.json. No device model is ever consulted.
public struct LayoutMetrics: Sendable, Equatable {
    // Vertical
    public var stripHeight: CGFloat
    /// Gap between the strip and the first key row.
    public var topGap: CGFloat
    public var keyHeight: CGFloat
    public var rowGap: CGFloat
    public var bottomInset: CGFloat
    /// Default total keyboard height (strip + rows) for phones in portrait, at `heightScale` 1. Owner choice: 295 pt.
    public static let phonePortraitDefaultHeight: CGFloat = 295
    /// The part of it below the 44 pt suggestion strip (rows); the strip height itself is unchanged.
    public static let phonePortraitDefaultBody: CGFloat = phonePortraitDefaultHeight - 44

    /// Scale applied to the reference vertical tokens (1 at 390x260 portrait).
    public var verticalScale: CGFloat

    // Horizontal (letters / 123 / #+= grid)
    public var columnGap: CGFloat
    public var contentLeft: CGFloat
    public var contentWidth: CGFloat
    public var keyWidth: CGFloat
    /// Shift, delete, 123/#+= toggle on the third row.
    public var functionKeyWidth: CGFloat
    /// 123/ABC and return on the bottom row.
    public var sideKeyWidth: CGFloat
    /// @ . , keys next to space.
    public var tailKeyWidth: CGFloat

    public var cornerRadius: CGFloat

    // Number / decimal / phone pads
    public var padContentLeft: CGFloat
    public var padKeyWidth: CGFloat

    // Duo modes (see `DuoMode`)
    public var mode: DuoMode = .standard
    /// Split: x extents of the left and right key halves (key caps stay inside them, never in the fold band).
    public var splitLeftMinX: CGFloat = 0
    public var splitLeftMaxX: CGFloat = 0
    public var splitRightMinX: CGFloat = 0
    public var splitRightMaxX: CGFloat = 0
    /// Fill to fold: x extent of the reserved arrow/edit column (0 width when not in that mode).
    public var auxColumnMinX: CGFloat = 0
    public var auxColumnWidth: CGFloat = 0

    /// F13 landscape side columns (phones): key width of each side column (0 = none) and the x of its left edge /
    /// right edge. Side keys use the normal key height.
    public var sideColumnWidth: CGFloat = 0
    public var sideLeftMinX: CGFloat = 0
    public var sideRightMaxX: CGFloat = 0

    // MARK: Reference tokens (iPhone 12 portrait, measured) and estimates

    struct Reference {
        var stripHeight: CGFloat
        var topGap: CGFloat
        var keyHeight: CGFloat
        var rowGap: CGFloat
        var bottomInset: CGFloat

        func total(rows: Int) -> CGFloat {
            stripHeight + topGap + CGFloat(rows) * keyHeight + CGFloat(rows - 1) * rowGap + bottomInset
        }
        /// Everything except the strip, for `rows` rows.
        func body(rows: Int) -> CGFloat { total(rows: rows) - stripHeight }
    }

    /// Measured: strip 44, row tops 52/106/160/214 (key 43, pitch 54), view ends at 260 (spike M0-04 height).
    static let portraitLetters = Reference(stripHeight: 44, topGap: 8, keyHeight: 43, rowGap: 11, bottomInset: 3)
    /// Measured: pad tiles 48 high, pitch 54, first row top 50 (= 44 + 6).
    static let portraitPad = Reference(stripHeight: 44, topGap: 6, keyHeight: 48, rowGap: 6, bottomInset: 0)
    /// ESTIMATED (landscape not captured).
    static let landscapeLetters = Reference(stripHeight: 32, topGap: 6, keyHeight: 36, rowGap: 7, bottomInset: 3)
    /// ESTIMATED.
    static let landscapePad = Reference(stripHeight: 32, topGap: 6, keyHeight: 34, rowGap: 8, bottomInset: 4)

    static let referenceWidth: CGFloat = 390
    static let referenceColumnGap: CGFloat = 6
    static let referenceEdgeMargin: CGFloat = 6.67
    static let referencePadEdgeMargin: CGFloat = 5.33
    /// shift/delete width over letter width: 43.67 / 32.33.
    static let functionKeyFactor: CGFloat = 1.353
    /// 123 / return width over letter width: 89.67 / 32.33.
    static let sideKeyFactor: CGFloat = 2.78
    /// @ and . next to space on the email keyboard: 42 / 32.33.
    static let tailKeyFactor: CGFloat = 1.3
    /// ESTIMATED cap for key width on the Duo inner display (D-20: "capped key size").
    static let duoInnerMaxKeyWidth: CGFloat = 56
    /// ESTIMATED caps for the Duo outer display (wider/shorter than a phone): keys do not stretch to the full width.
    static let duoOuterMaxKeyWidthPortrait: CGFloat = 40
    static let duoOuterMaxKeyWidthLandscape: CGFloat = 46
    /// ESTIMATED default height ratio of the Duo outer display in portrait (phone = 1).
    static let duoOuterHeightFactorPortrait: CGFloat = 0.88
    /// ESTIMATED: key width cap per half in the split layout.
    static let splitMaxKeyWidth: CGFloat = 72
    /// ESTIMATED: key width cap in laptop "fill to fold" (bigger keys than the inner cap).
    static let fillToFoldMaxKeyWidth: CGFloat = 72
    /// ESTIMATED: share of the width reserved for the arrow/edit column in laptop mode, with min/max in pt.
    static let auxColumnShare: CGFloat = 0.14
    static let auxColumnMin: CGFloat = 96
    static let auxColumnMax: CGFloat = 160
    /// ESTIMATED cap for the numeric pad block width.
    static let maxPadWidth: CGFloat = 520
    /// Landscape side columns (F13): only when the available width is at least this (iPhone SE-size landscapes
    /// have no room), width share of one column and its clamp in pt. ESTIMATED.
    static let sideColumnMinAvailWidth: CGFloat = 640
    static let sideColumnShare: CGFloat = 0.075
    static let sideColumnMin: CGFloat = 40
    static let sideColumnMax: CGFloat = 64

    static func hasSideColumns(kind: LayoutKind, traits: LayoutTraits, settings: LayoutSettings, availWidth: CGFloat) -> Bool {
        settings.landscapeSideKeys && kind == .letters && traits.displayClass == .phone
            && traits.orientation == .landscape && availWidth >= sideColumnMinAvailWidth
    }

    /// Compact chrome (`LayoutSettings.compact`): strip 44 -> 36 (portrait) / 32 -> 28, key gap 6 -> 4.5, side margin
    /// 6.67 -> 4, keys 43 -> 46 high, rows 11 -> 8 apart. Pads are left alone.
    static let compactColumnGap: CGFloat = 4.5
    static let compactEdgeMargin: CGFloat = 4

    static func reference(kind: LayoutKind, orientation: LayoutOrientation, compact: Bool = false) -> Reference {
        let base = reference(kind: kind, orientation: orientation)
        guard compact, !kind.isPad else { return base }
        return orientation == .portrait
            ? Reference(stripHeight: 36, topGap: 4, keyHeight: 46, rowGap: 8, bottomInset: 3)
            : Reference(stripHeight: 28, topGap: 4, keyHeight: 38, rowGap: 6, bottomInset: 3)
    }

    static func reference(kind: LayoutKind, orientation: LayoutOrientation) -> Reference {
        switch (kind.isPad, orientation) {
        case (false, .portrait): portraitLetters
        case (true, .portrait): portraitPad
        case (false, .landscape): landscapeLetters
        case (true, .landscape): landscapePad
        }
    }

    /// Resolve how the key area is arranged. Rules only (container size, traits, settings), never a device model.
    public static func duoMode(
        containerSize: CGSize, traits: LayoutTraits, kind: LayoutKind, settings: LayoutSettings
    ) -> DuoMode {
        guard traits.displayClass == .duoInner, !kind.isPad else { return .standard }
        if settings.fillToFold && traits.orientation == .landscape { return .fillToFold }
        guard settings.isSplit(for: traits.orientation) else { return .standard }
        let given = settings.centreGap
        return .split(CentreGap(
            centerX: given?.centerX ?? containerSize.width / 2,
            width: max(given?.width ?? DuoGeometry.foldBandWidth, DuoGeometry.foldBandWidth)
        ))
    }

    /// Settings after mode rules: the laptop mode always shows the number row (letters layer).
    static func effectiveSettings(_ settings: LayoutSettings, mode: DuoMode) -> LayoutSettings {
        var s = settings
        if mode == .fillToFold { s.numberRow = true }
        return s
    }

    static func rowCount(kind: LayoutKind, settings: LayoutSettings) -> Int {
        if kind.isPad { return 4 }
        return kind == .letters && settings.numberRow ? 5 : 4
    }

    /// Resolve every token for a container.
    ///
    /// Rules:
    /// - Strip height is fixed (44 portrait / 32 landscape). The rest of the height is shared by rows: all vertical
    ///   tokens are multiplied by `(height - strip - safe.bottom) / referenceBody`, so a 390x260 container gives
    ///   exactly the measured tokens and any other height scales linearly.
    /// - Column gap = 6 pt, growing with width up to x1.25 (6 -> 7.5).
    /// - Edge margin = 6.67 x clamp(width / 390, 0.96, 1.15).
    /// - Letter width = (content - 9 gaps) / 10, content = width - safe L/R - 2 margins; on the Duo inner display
    ///   the letter width is capped (56 pt) and the block is centred.
    /// - Function key widths are fixed multiples of the letter width (shift/delete 1.353, 123/return 2.78,
    ///   @ . 1.3), which reproduces the measured third and bottom rows at 390 pt.
    public static func resolve(
        containerSize: CGSize,
        safeArea: LayoutInsets,
        traits: LayoutTraits,
        kind: LayoutKind,
        settings rawSettings: LayoutSettings
    ) -> LayoutMetrics {
        let mode = duoMode(containerSize: containerSize, traits: traits, kind: kind, settings: rawSettings)
        let settings = effectiveSettings(rawSettings, mode: mode)
        var ref = reference(kind: kind, orientation: traits.orientation, compact: settings.compact)
        ref.stripHeight += settings.searchRowHeight
        let rows = rowCount(kind: kind, settings: settings)

        let availableHeight = max(containerSize.height - safeArea.bottom - ref.stripHeight, 1)
        let v = max(availableHeight / ref.body(rows: rows), 0.1)

        let availW = max(containerSize.width - safeArea.left - safeArea.right, 1)
        let widthRatio = availW / referenceWidth
        let compactKeys = settings.compact && !kind.isPad
        let gap = (compactKeys ? compactColumnGap : referenceColumnGap) * min(max(widthRatio, 1), 1.25)
        let margin = (compactKeys ? compactEdgeMargin : referenceEdgeMargin) * min(max(widthRatio, 0.96), 1.15)

        var keyWidth = (availW - 2 * margin - 9 * gap) / 10
        var regionWidth = availW   // horizontal space the standard block is centred in
        var auxWidth: CGFloat = 0
        var sideW: CGFloat = 0
        if hasSideColumns(kind: kind, traits: traits, settings: settings, availWidth: availW) {
            sideW = min(max(availW * sideColumnShare, sideColumnMin), sideColumnMax)
            regionWidth = availW - 2 * (sideW + gap)
            keyWidth = (regionWidth - 2 * margin - 9 * gap) / 10
        }
        switch traits.displayClass {
        case .duoInner:
            if mode == .fillToFold {
                auxWidth = min(max(availW * auxColumnShare, auxColumnMin), auxColumnMax)
                regionWidth = availW - auxWidth
                keyWidth = min((regionWidth - 2 * margin - 9 * gap) / 10, fillToFoldMaxKeyWidth)
            } else {
                keyWidth = min(keyWidth, duoInnerMaxKeyWidth)
            }
        case .duoOuter:
            keyWidth = min(
                keyWidth,
                traits.orientation == .portrait ? duoOuterMaxKeyWidthPortrait : duoOuterMaxKeyWidthLandscape
            )
        case .phone: break
        }
        let contentWidth = 10 * keyWidth + 9 * gap
        let contentLeft = safeArea.left + (sideW > 0 ? sideW + gap : 0) + (regionWidth - contentWidth) / 2

        let padMargin = referencePadEdgeMargin * min(max(widthRatio, 0.96), 1.15)
        let padWidth = min(availW - 2 * padMargin, maxPadWidth)
        let padKeyWidth = (padWidth - 2 * gap) / 3
        let padLeft = safeArea.left + (availW - padWidth) / 2

        let radiusBase: CGFloat = kind.isPad ? 10.6 : 8.5

        var out = LayoutMetrics(
            stripHeight: ref.stripHeight,
            topGap: ref.topGap * v,
            keyHeight: ref.keyHeight * v,
            rowGap: ref.rowGap * v,
            bottomInset: ref.bottomInset * v + safeArea.bottom,
            verticalScale: v,
            columnGap: gap,
            contentLeft: contentLeft,
            contentWidth: contentWidth,
            keyWidth: keyWidth,
            functionKeyWidth: keyWidth * functionKeyFactor,
            sideKeyWidth: keyWidth * sideKeyFactor,
            tailKeyWidth: keyWidth * tailKeyFactor,
            cornerRadius: radiusBase * min(max(v, 0.85), 1.25),
            padContentLeft: padLeft,
            padKeyWidth: padKeyWidth
        )
        out.mode = mode
        if sideW > 0 {
            out.sideColumnWidth = sideW
            out.sideLeftMinX = safeArea.left + margin
            out.sideRightMaxX = safeArea.left + availW - margin
            // The block is inset by the margin on both sides already (keyWidth accounts for it); shift it past the columns.
            out.contentLeft = safeArea.left + margin + sideW + gap
            out.contentWidth = regionWidth - 2 * margin
        }
        if mode == .fillToFold {
            out.auxColumnWidth = auxWidth - margin
            out.auxColumnMinX = safeArea.left + availW - auxWidth
        }
        if case .split(let gapSpec) = mode {
            out.applySplit(gap: gapSpec, safeLeft: safeArea.left, availW: availW, margin: margin)
        }
        return out
    }

    /// Split rules. A half is a 5-column grid: key width = (half width - 4 gaps) / 5, capped; halves are anchored to
    /// the outer edges (thumbs), so a cap only widens the centre, never narrows the gap below the fold band.
    private mutating func applySplit(gap spec: CentreGap, safeLeft: CGFloat, availW: CGFloat, margin: CGFloat) {
        let bandMin = spec.centerX - spec.width / 2, bandMax = spec.centerX + spec.width / 2
        let outerLeft = safeLeft + margin, outerRight = safeLeft + availW - margin
        let room = max(min(bandMin - outerLeft, outerRight - bandMax), 5)
        let kw = min((room - 4 * columnGap) / 5, Self.splitMaxKeyWidth)
        let half = 5 * kw + 4 * columnGap
        keyWidth = kw
        functionKeyWidth = kw * Self.functionKeyFactor
        sideKeyWidth = kw * Self.sideKeyFactor
        tailKeyWidth = kw * Self.tailKeyFactor
        splitLeftMinX = outerLeft
        splitLeftMaxX = outerLeft + half
        splitRightMaxX = outerRight
        splitRightMinX = outerRight - half
        contentLeft = outerLeft
        contentWidth = outerRight - outerLeft
    }
}
