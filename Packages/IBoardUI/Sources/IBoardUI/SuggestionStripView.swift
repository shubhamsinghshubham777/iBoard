#if canImport(UIKit)
import UIKit
import IBoardLayout
import IBoardTheme

/// The suggestion strip (M1-06): three slots for now (static, empty until F2), and an alternates row mode used by
/// long-press (D-08: alternates live here, never in a balloon; P-15: everything stays inside the keyboard bounds).
///
/// Transparent (P-22). Not interactive: touches fall through to the key grid, which owns the touch that started an
/// alternates session and feeds `highlight(for:)`.
@MainActor
public final class SuggestionStripView: UIView {
    public static let slotCount = 3

    public var appearance: ThemeAppearance = .light { didSet { if appearance != oldValue { applyColors() } } }

    /// Slot text (static placeholders until F2 supplies candidates). Ignored while the alternates row shows.
    public var slotTexts: [String] = ["", "", ""] { didSet { relayout() } }

    /// Slots drawn as a highlighted chip (a prominent one-time code, M6-03).
    public var emphasizedSlots: Set<Int> = [] { didSet { if emphasizedSlots != oldValue { relayout() } } }

    /// One line across the whole strip (selection preview, M5-05). Replaces the slots while set.
    public var bannerText: String? { didSet { if bannerText != oldValue { relayout() } } }
    /// Action row (selection actions): equal cells, a disabled one is dimmed. Replaces the slots while non-empty.
    public var actionTitles: [String] = [] { didSet { if actionTitles != oldValue { relayout() } } }
    public var actionEnabled: [Bool] = [] { didSet { if actionEnabled != oldValue { relayout() } } }
    public var isShowingActions: Bool { !actionTitles.isEmpty }

    /// Cell index of the action row at `x` (strip-local), nil when no row is showing.
    public func actionIndex(forLocalX x: CGFloat) -> Int? {
        guard !actionTitles.isEmpty, bounds.width > 0 else { return nil }
        let x0 = actionsOriginX(bounds.width)
        guard x >= x0 else { return nil }
        let i = Int((x - x0) / ((bounds.width - x0) / CGFloat(actionTitles.count)))
        return i >= 0 && i < actionTitles.count ? i : nil
    }

    public private(set) var selection: AlternatesSelection?

    private let slotLabels = (0..<SuggestionStripView.slotCount).map { _ in UILabel() }
    private let dividers = (0..<SuggestionStripView.slotCount - 1).map { _ in CALayer() }
    private let highlightLayer = CALayer()
    private let emphasisLayers = (0..<SuggestionStripView.slotCount).map { _ in CALayer() }
    private var altLabels: [UILabel] = []
    private let bannerLabel = UILabel()
    private var actionLabels: [UILabel] = []
    private var tokens = NativeThemeTokens.light

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for l in slotLabels {
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 16)
            l.lineBreakMode = .byTruncatingTail
            addSubview(l)
        }
        bannerLabel.textAlignment = .center
        bannerLabel.font = .systemFont(ofSize: 15)
        bannerLabel.lineBreakMode = .byTruncatingMiddle
        bannerLabel.isHidden = true
        addSubview(bannerLabel)
        for d in dividers { layer.addSublayer(d) }
        for e in emphasisLayers {
            e.cornerCurve = .continuous
            e.isHidden = true
            layer.insertSublayer(e, at: 0)
        }
        highlightLayer.cornerCurve = .continuous
        highlightLayer.isHidden = true
        layer.insertSublayer(highlightLayer, at: 0)
        accessibilityIdentifier = "suggestion-strip"
        applyColors()
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    // MARK: Alternates mode

    public var isShowingAlternates: Bool { selection != nil }

    /// Replace the three slots with the alternates row. `uppercase` is applied by the caller to the options.
    public func beginAlternates(_ new: AlternatesSelection) {
        selection = new
        while altLabels.count < new.options.count {
            let l = UILabel()
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 22)
            addSubview(l)
            altLabels.append(l)
        }
        for (i, l) in altLabels.enumerated() {
            l.isHidden = i >= new.options.count
            if i < new.options.count { l.text = new.options[i] }
        }
        relayout()
    }

    /// Feed the finger position (view coordinates); returns nothing, redraws the highlight.
    public func move(to point: CGPoint) {
        guard selection != nil else { return }
        selection!.move(to: point)
        relayout()
    }

    /// Finger lifted: returns the alternate to insert (nil when cancelled) and restores the three slots.
    public func end(at point: CGPoint) -> String? {
        guard selection != nil else { return nil }
        let result = selection!.end(at: point)
        cancelAlternates()
        return result
    }

    public func cancelAlternates() {
        selection = nil
        for l in altLabels { l.isHidden = true }
        relayout()
    }

    // MARK: Layout

    private func applyColors() {
        tokens = NativeThemeTokens.tokens(for: appearance)
        let label = UIColor(cgColor: tokens.keyLabel.cgColor)
        for l in slotLabels { l.textColor = label }
        for l in altLabels { l.textColor = label }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for d in dividers { d.backgroundColor = tokens.keyLabel.cgColor.copy(alpha: 0.18) }
        highlightLayer.backgroundColor = tokens.actionKeyFill.cgColor
        for e in emphasisLayers { e.backgroundColor = tokens.actionKeyFill.cgColor }
        CATransaction.commit()
        relayout()
    }

    /// With a banner AND actions the banner takes the left part and the cells share the rest.
    private func actionsOriginX(_ w: CGFloat) -> CGFloat { bannerText != nil ? w * 0.36 : 0 }

    private func layoutOverlay(w: CGFloat, h: CGFloat) {
        let label = UIColor(cgColor: tokens.keyLabel.cgColor)
        bannerLabel.isHidden = bannerText == nil
        bannerLabel.text = bannerText
        bannerLabel.textColor = label
        let x0 = actionsOriginX(w)
        bannerLabel.frame = CGRect(x: 6, y: 0, width: (actionTitles.isEmpty ? w : x0) - 12, height: h)
        bannerLabel.font = .systemFont(ofSize: actionTitles.isEmpty ? 15 : 12)
        while actionLabels.count < actionTitles.count {
            let l = UILabel()
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 14, weight: .medium)
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.7
            addSubview(l)
            actionLabels.append(l)
        }
        let n = max(actionTitles.count, 1)
        for (i, l) in actionLabels.enumerated() {
            l.isHidden = i >= actionTitles.count
            guard i < actionTitles.count else { continue }
            l.text = actionTitles[i]
            let enabled = i < actionEnabled.count ? actionEnabled[i] : true
            l.textColor = label.withAlphaComponent(enabled ? 1 : 0.3)
            let cell = (w - x0) / CGFloat(n)
            l.frame = CGRect(x: x0 + CGFloat(i) * cell, y: 0, width: cell, height: h)
        }
    }

    private func relayout() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let alt = selection
        let overlay = bannerText != nil || !actionTitles.isEmpty
        layoutOverlay(w: w, h: h)
        let slotW = w / CGFloat(Self.slotCount)
        for (i, l) in slotLabels.enumerated() {
            l.frame = CGRect(x: CGFloat(i) * slotW, y: 0, width: slotW, height: h)
            l.text = i < slotTexts.count ? slotTexts[i] : ""
            l.isHidden = alt != nil || overlay
            let on = alt == nil && !overlay && emphasizedSlots.contains(i) && !(l.text ?? "").isEmpty
            l.textColor = UIColor(cgColor: (on ? tokens.actionKeyLabel : tokens.keyLabel).cgColor)
            l.font = .systemFont(ofSize: 16, weight: on ? .semibold : .regular)
            let e = emphasisLayers[i]
            e.isHidden = !on
            e.frame = l.frame.insetBy(dx: 4, dy: 5)
            e.cornerRadius = min(e.frame.height, e.frame.width) / 3
        }
        for (i, d) in dividers.enumerated() {
            d.frame = CGRect(x: slotW * CGFloat(i + 1) - 0.25, y: h * 0.25, width: 0.5, height: h * 0.5)
            d.isHidden = alt != nil || overlay
        }
        guard let alt else { highlightLayer.isHidden = true; return }
        for (i, l) in altLabels.enumerated() where i < alt.options.count {
            l.frame = alt.cellFrame(i).offsetBy(dx: -frame.minX, dy: -frame.minY)
            let on = alt.highlighted == i
            l.textColor = UIColor(cgColor: (on ? tokens.actionKeyLabel : tokens.keyLabel).cgColor)
        }
        if let hi = alt.highlighted {
            highlightLayer.isHidden = false
            let cell = alt.cellFrame(hi).offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: 2, dy: 4)
            highlightLayer.frame = cell
            highlightLayer.cornerRadius = min(cell.height, cell.width) / 4
        } else {
            highlightLayer.isHidden = true
        }
    }
}
#endif
