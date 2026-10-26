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
    /// ESTIMATED cap for the numeric pad block width.
    static let maxPadWidth: CGFloat = 520

    static func reference(kind: LayoutKind, orientation: LayoutOrientation) -> Reference {
        switch (kind.isPad, orientation) {
        case (false, .portrait): portraitLetters
        case (true, .portrait): portraitPad
        case (false, .landscape): landscapeLetters
        case (true, .landscape): landscapePad
        }
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
        settings: LayoutSettings
    ) -> LayoutMetrics {
        let ref = reference(kind: kind, orientation: traits.orientation)
        let rows = rowCount(kind: kind, settings: settings)

        let availableHeight = max(containerSize.height - safeArea.bottom - ref.stripHeight, 1)
        let v = max(availableHeight / ref.body(rows: rows), 0.1)

        let availW = max(containerSize.width - safeArea.left - safeArea.right, 1)
        let widthRatio = availW / referenceWidth
        let gap = referenceColumnGap * min(max(widthRatio, 1), 1.25)
        let margin = referenceEdgeMargin * min(max(widthRatio, 0.96), 1.15)

        var keyWidth = (availW - 2 * margin - 9 * gap) / 10
        if traits.displayClass == .duoInner { keyWidth = min(keyWidth, duoInnerMaxKeyWidth) }
        let contentWidth = 10 * keyWidth + 9 * gap
        let contentLeft = safeArea.left + (availW - contentWidth) / 2

        let padMargin = referencePadEdgeMargin * min(max(widthRatio, 0.96), 1.15)
        let padWidth = min(availW - 2 * padMargin, maxPadWidth)
        let padKeyWidth = (padWidth - 2 * gap) / 3
        let padLeft = safeArea.left + (availW - padWidth) / 2

        let radiusBase: CGFloat = kind.isPad ? 10.6 : 8.5

        return LayoutMetrics(
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
    }
}
