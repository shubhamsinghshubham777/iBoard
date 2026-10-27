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

    /// Colours / weights from the selected theme (Native by default).
    public var skin: KeyboardSkin = .native(.light) { didSet { if skin != oldValue { applyColors() } } }
    public var appearance: ThemeAppearance { skin.appearance }

    /// Slot text (static placeholders until F2 supplies candidates). Ignored while the alternates row shows.
    public var slotTexts: [String] = ["", "", ""] { didSet { relayout() } }

    /// Slots drawn bold (the engine's best reading).
    public var boldSlots: Set<Int> = [] { didSet { if boldSlots != oldValue { relayout() } } }

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
        let area = overlayRects(w: bounds.width).actions
        guard x >= area.minX, x < area.maxX else { return nil }
        let i = Int((x - area.minX) / (area.width / CGFloat(actionTitles.count)))
        return i >= 0 && i < actionTitles.count ? i : nil
    }

    /// Duo split (D-20): usable x ranges in STRIP-local coordinates (the fold band lies between them). Empty or one
    /// entry = a single run across the whole strip. With two, the left one holds slots 0 and 1, the right one slot 2.
    public var segments: [CGRect] = [] { didSet { if segments != oldValue { relayout() } } }

    public private(set) var selection: AlternatesSelection?

    /// Slot rectangles (strip-local, full height) for the current segments.
    func slotRects(width w: CGFloat, height h: CGFloat) -> [CGRect] {
        if segments.count == 2 {
            let l = segments[0], r = segments[1]
            let half = l.width / 2
            return [CGRect(x: l.minX, y: 0, width: half, height: h), CGRect(x: l.minX + half, y: 0, width: half, height: h),
                    CGRect(x: r.minX, y: 0, width: r.width, height: h)]
        }
        let slotW = w / CGFloat(Self.slotCount)
        return (0..<Self.slotCount).map { CGRect(x: CGFloat($0) * slotW, y: 0, width: slotW, height: h) }
    }

    /// The slot under a strip-local x (the nearest slot over the fold band).
    public func slotIndex(forLocalX x: CGFloat) -> Int {
        let rects = slotRects(width: bounds.width, height: max(bounds.height, 1))
        if let i = rects.firstIndex(where: { x >= $0.minX && x < $0.maxX }) { return i }
        if x >= (rects.last?.maxX ?? 0) { return rects.count - 1 }
        return x < (rects.first?.minX ?? 0) ? 0 : (segments.count == 2 ? 1 : rects.count - 1)
    }

    /// Where the banner / action row may draw (strip-local): the whole strip, or the runs of a split.
    private func overlayRects(w: CGFloat) -> (banner: CGRect, actions: CGRect) {
        let h = bounds.height
        if segments.count == 2 {
            // Banner left, actions right; an action row without a banner takes the left run.
            return (segments[0].with(h), bannerText != nil ? segments[1].with(h) : segments[0].with(h))
        }
        let x0 = actionsOriginX(w)
        return (CGRect(x: 0, y: 0, width: x0 == 0 ? w : x0, height: h), CGRect(x: x0, y: 0, width: w - x0, height: h))
    }

    /// Points the slot content sits above the strip's centre (see `relayout`).
    static let upwardBias: CGFloat = 6

    private let slotLabels = (0..<SuggestionStripView.slotCount).map { _ in UILabel() }
    private let dividers = (0..<SuggestionStripView.slotCount - 1).map { _ in CALayer() }
    private let highlightLayer = CALayer()
    private let emphasisLayers = (0..<SuggestionStripView.slotCount).map { _ in CALayer() }
    private var altLabels: [UILabel] = []
    /// SF Symbol images for action options (settings, clipboard); parallel to `altLabels`.
    private var altIcons: [UIImageView] = []
    /// Rounded plate under the alternates row (a native-looking popup tile strip).
    private let altPlate = CALayer()
    private let bannerLabel = UILabel()
    /// Emoji search field (rounded pill with a magnifier and, once there is a query, a clear button). It takes slot 0
    /// (or the whole strip when `wide`); the other slots still show their texts when not wide.
    public struct SearchField: Equatable, Sendable {
        public var text: String
        public var placeholder: String
        public var wide: Bool
        /// A text button after the pill (e.g. "Cancel").
        public var trailingAction: String?
        /// Typing goes into the field: a blinking caret shows after the text.
        public var focused: Bool
        public init(text: String, placeholder: String, wide: Bool, trailingAction: String? = nil, focused: Bool = false) {
            self.text = text; self.placeholder = placeholder; self.wide = wide; self.trailingAction = trailingAction
            self.focused = focused
        }
    }
    /// Height (pt) of the results row under the field while emoji search shows it; the field then sits in the strip's
    /// top part (`bounds.height - searchRowExtra`).
    static let searchFieldHeight: CGFloat = 34
    public var searchRowExtra: CGFloat = 0 { didSet { if searchRowExtra != oldValue { relayout() } } }
    public var searchField: SearchField? { didSet { if searchField != oldValue { relayout() } } }
    /// Width of the clear button's tap zone at the right end of the pill (strip points).
    public static let searchClearZone: CGFloat = 52
    /// Width reserved for the trailing text button.
    public static let searchActionWidth: CGFloat = 72
    private let trailingLabel = UILabel()
    private let caret = CALayer()

    private let pillLayer = CALayer()
    private let searchLabel = UILabel()
    private let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let clearIcon = UIImageView(image: UIImage(systemName: "face.smiling"))

    private var actionLabels: [UILabel] = []
    private var tokens = NativeThemeTokens.light
    private let chipLayers = (0..<SuggestionStripView.slotCount).map { _ in CALayer() }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for l in slotLabels {
            l.textAlignment = .center
            l.font = scaledFont(16)
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.75
            l.lineBreakMode = .byTruncatingTail
            addSubview(l)
        }
        bannerLabel.textAlignment = .center
        bannerLabel.font = scaledFont(15)
        bannerLabel.lineBreakMode = .byTruncatingMiddle
        bannerLabel.adjustsFontSizeToFitWidth = true
        bannerLabel.minimumScaleFactor = 0.75
        bannerLabel.isHidden = true
        addSubview(bannerLabel)
        pillLayer.cornerCurve = .continuous
        pillLayer.isHidden = true
        layer.insertSublayer(pillLayer, at: 0)
        searchLabel.font = scaledFont(16)
        searchLabel.lineBreakMode = .byTruncatingHead
        searchLabel.isHidden = true
        addSubview(searchLabel)
        caret.cornerRadius = 1
        caret.isHidden = true
        layer.addSublayer(caret)
        trailingLabel.font = scaledFont(16)
        trailingLabel.textAlignment = .center
        trailingLabel.isHidden = true
        addSubview(trailingLabel)
        for v in [magnifier, clearIcon] { v.contentMode = .scaleAspectFit; v.isHidden = true; addSubview(v) }
        for d in dividers { layer.addSublayer(d) }
        for c in chipLayers {
            c.cornerCurve = .continuous
            c.isHidden = true
            layer.insertSublayer(c, at: 0)
        }
        for e in emphasisLayers {
            e.cornerCurve = .continuous
            e.isHidden = true
            layer.insertSublayer(e, at: 0)
        }
        highlightLayer.cornerCurve = .continuous
        highlightLayer.isHidden = true
        layer.insertSublayer(highlightLayer, at: 0)
        altPlate.cornerCurve = .continuous
        altPlate.isHidden = true
        altPlate.shadowOpacity = 0.18
        altPlate.shadowRadius = 5
        altPlate.shadowOffset = CGSize(width: 0, height: 1)
        layer.insertSublayer(altPlate, at: 0) // below the highlight
        accessibilityIdentifier = "suggestion-strip"
        applyColors()
        // M13-01: Dynamic Type (capped, the strip has a fixed height) and Reduce Motion changes apply live.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: SuggestionStripView, _) in
            self.relayout()
        }
        NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reduceMotionChanged() }
        }
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    /// A font that follows the user's text size but never outgrows the strip (`StripTypeScale`).
    private func scaledFont(_ base: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traitCollection)
        return .systemFont(ofSize: StripTypeScale.size(base: base, scaled: scaled), weight: weight)
    }

    /// Reduce Motion switched on: a blinking caret stops at once instead of at the next layout.
    private func reduceMotionChanged() {
        if UIAccessibility.isReduceMotionEnabled { caret.removeAnimation(forKey: "blink") }
        relayout()
    }

    /// Strip slots that offer VoiceOver custom actions (name list per slot), e.g. "Forget suggestion" or "Open clipboard
    /// history". `onAccessibilityAction(slot, index)` runs the chosen one.
    public var slotAccessibilityActions: [Int: [String]] = [:]
    /// Optional per-slot VoiceOver hint replacing "Suggestion" (e.g. the Messages code chip).
    public var slotAccessibilityHints: [Int: String] = [:]
    public var onAccessibilityAction: ((Int, Int) -> Void)?

    public override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    // MARK: VoiceOver (M13-01)

    /// VoiceOver double tap on a slot / action cell; the point is strip-local (the host feeds it through the same path
    /// as a finger tap).
    public var onAccessibilityActivate: ((CGPoint) -> Void)?

    public override var isAccessibilityElement: Bool { get { false } set {} }

    public override var accessibilityElements: [Any]? {
        get {
            guard bounds.width > 0, selection == nil else { return [] }
            func element(_ label: String, _ rect: CGRect, hint: String? = nil) -> UIAccessibilityElement {
                let e = StripElement(accessibilityContainer: self)
                e.accessibilityLabel = label
                e.accessibilityHint = hint
                e.accessibilityTraits = [.button]
                e.accessibilityUserInputLabels = [label]
                e.accessibilityFrameInContainerSpace = rect
                let c = CGPoint(x: rect.midX, y: rect.midY)
                e.onActivate = { [weak self] in self?.onAccessibilityActivate?(c) }
                return e
            }
            var out: [UIAccessibilityElement] = []
            if !actionTitles.isEmpty {
                let area = overlayRects(w: bounds.width).actions
                let w = area.width / CGFloat(actionTitles.count)
                if let b = bannerText {
                    let t = UIAccessibilityElement(accessibilityContainer: self)
                    t.accessibilityLabel = b
                    t.accessibilityTraits = [.staticText]
                    t.accessibilityFrameInContainerSpace = overlayRects(w: bounds.width).banner
                    out.append(t)
                }
                for (i, title) in actionTitles.enumerated() {
                    let e = element(title, CGRect(x: area.minX + CGFloat(i) * w, y: 0, width: w, height: bounds.height))
                    if i < actionEnabled.count, !actionEnabled[i] { e.accessibilityTraits.insert(.notEnabled) }
                    out.append(e)
                }
                return out
            }
            if let b = bannerText {
                let t = UIAccessibilityElement(accessibilityContainer: self)
                t.accessibilityLabel = b
                t.accessibilityTraits = [.staticText]
                t.accessibilityFrameInContainerSpace = bounds
                return [t]
            }
            if let f = searchField, f.wide {
                // The emoji panel's search pill (the keys type into it) and its Cancel button.
                let actionW = f.trailingAction == nil ? 0 : Self.searchActionWidth
                let pill = CGRect(x: 14, y: 0, width: max(1, bounds.width - 28 - actionW), height: bounds.height)
                let field = element(f.text.isEmpty ? f.placeholder : "Search emoji, \(f.text)", pill,
                                    hint: f.trailingAction == nil ? "Double tap to search with the keyboard" : nil)
                field.accessibilityTraits = f.focused ? [.searchField, .selected] : [.searchField]
                var list: [UIAccessibilityElement] = [field]
                if let cancel = f.trailingAction {
                    list.append(element(cancel, CGRect(x: bounds.width - actionW, y: 0, width: actionW, height: bounds.height)))
                }
                return list
            }
            let rects = slotRects(width: bounds.width, height: bounds.height)
            for (i, text) in slotTexts.enumerated() where i < rects.count {
                guard let label = KeyAccessibility.stripLabel(slotIndex: i, text: text) else { continue }
                let e = element(label, rects[i], hint: slotAccessibilityHints[i] ?? "Suggestion")
                if let names = slotAccessibilityActions[i], !names.isEmpty {
                    e.accessibilityCustomActions = names.enumerated().map { idx, name in
                        UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.onAccessibilityAction?(i, idx); return true }
                    }
                }
                if boldSlots.contains(i) { e.accessibilityHint = "Best suggestion" }
                out.append(e)
            }
            return out
        }
        set {}
    }

    /// Rotor "Suggestions": flick up/down to walk only the suggestion slots (skips banners, action cells, search field).
    public override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get {
            let rotor = UIAccessibilityCustomRotor(name: "Suggestions") { [weak self] predicate in
                guard let self else { return nil }
                let slots = (self.accessibilityElements as? [StripElement])?.filter { $0.accessibilityHint == "Suggestion" || $0.accessibilityHint == "Best suggestion" } ?? []
                guard !slots.isEmpty else { return nil }
                let forward = predicate.searchDirection == .next
                let cur = predicate.currentItem.targetElement as? StripElement
                let idx = cur.flatMap { c in slots.firstIndex { $0.accessibilityLabel == c.accessibilityLabel } }
                let next: Int = idx.map { forward ? $0 + 1 : $0 - 1 } ?? (forward ? 0 : slots.count - 1)
                guard slots.indices.contains(next) else { return nil }
                return UIAccessibilityCustomRotorItemResult(targetElement: slots[next], targetRange: nil)
            }
            return [rotor]
        }
        set {}
    }

    private final class StripElement: UIAccessibilityElement {
        var onActivate: (() -> Void)?
        override func accessibilityActivate() -> Bool { onActivate?(); return true }
    }

    // MARK: Alternates mode

    public var isShowingAlternates: Bool { selection != nil }

    /// Replace the three slots with the alternates row. `uppercase` is applied by the caller to the options.
    public func beginAlternates(_ new: AlternatesSelection) {
        selection = new
        while altLabels.count < new.options.count {
            let l = UILabel()
            l.textAlignment = .center
            l.font = scaledFont(22)
            addSubview(l)
            altLabels.append(l)
            let v = UIImageView()
            v.contentMode = .center // the symbol keeps its configured size
            v.isHidden = true
            v.tintColor = UIColor(cgColor: skin.stripLabel.cgColor)
            addSubview(v)
            altIcons.append(v)
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: scaledFont(20).pointSize, weight: .regular)
        for (i, l) in altLabels.enumerated() {
            let option = i < new.options.count ? new.options[i] : nil
            let symbol = option.flatMap { KeyAlternates.symbolName(for: $0) }
            l.isHidden = option == nil || symbol != nil
            if let option, symbol == nil { l.text = option }
            let icon = altIcons[i]
            icon.isHidden = symbol == nil || option == nil
            icon.image = symbol.flatMap { UIImage(systemName: $0, withConfiguration: cfg) }
            icon.accessibilityLabel = option.flatMap { KeyAlternates.accessibilityLabel(for: $0) }
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
        for v in altIcons { v.isHidden = true }
        altPlate.isHidden = true
        relayout()
    }

    // MARK: Layout

    private func applyColors() {
        tokens = skin.tokens
        let label = UIColor(cgColor: skin.stripLabel.cgColor)
        for l in slotLabels { l.textColor = label }
        for l in altLabels { l.textColor = label }
        for v in altIcons { v.tintColor = label }
        magnifier.tintColor = label.withAlphaComponent(0.55)
        clearIcon.tintColor = label.withAlphaComponent(0.45)
        backgroundColor = skin.stripKind == .filled ? UIColor(cgColor: skin.stripBackground.cgColor) : .clear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for d in dividers { d.backgroundColor = skin.stripSeparator.cgColor }
        for c in chipLayers { c.backgroundColor = tokens.keyFill.cgColor }
        highlightLayer.backgroundColor = label.withAlphaComponent(0.14).cgColor
        altPlate.backgroundColor = tokens.keyFill.cgColor
        altPlate.shadowColor = UIColor.black.cgColor
        for e in emphasisLayers { e.backgroundColor = tokens.actionKeyFill.cgColor }
        pillLayer.backgroundColor = skin.stripLabel.cgColor.copy(alpha: 0.12)
        CATransaction.commit()
        relayout()
    }

    /// With a banner AND actions the banner takes the left part and the cells share the rest.
    private func actionsOriginX(_ w: CGFloat) -> CGFloat { bannerText != nil ? w * bannerShare : 0 }

    /// Share of the strip the banner takes when an action row sits beside it (0.36 for selections, more for tips).
    public var bannerShare: CGFloat = 0.36 { didSet { if bannerShare != oldValue { relayout() } } }

    private func layoutSearchField(rects: [CGRect], h: CGFloat, hidden: Bool) {
        guard let f = searchField, !hidden, let first = rects.first, let last = rects.last else {
            pillLayer.isHidden = true; searchLabel.isHidden = true; magnifier.isHidden = true; clearIcon.isHidden = true
            trailingLabel.isHidden = true
            hideCaret()
            return
        }
        let span = f.wide ? first.union(last) : first
        // Vertically centred in the strip's top part, so it has an even margin above (the keyboard's top edge) and below
        // (owner screenshot 2026-10-27: at y = 0 it touched the top edge).
        let trailW = f.trailingAction == nil ? 0 : Self.searchActionWidth
        let pillH = max(min(Self.searchFieldHeight, h - searchRowExtra - 2), 1)
        let pill = CGRect(x: span.minX + 14, y: max(0, ((h - searchRowExtra) - pillH) / 2), width: span.width - 28 - trailW, height: pillH)
        pillLayer.isHidden = false
        pillLayer.frame = pill
        pillLayer.cornerRadius = pill.height / 2
        magnifier.isHidden = false
        magnifier.frame = CGRect(x: pill.minX + 10, y: pill.midY - 9, width: 18, height: 18)
        // The emoji icon (back to the categories) only shows once the search is active, not in the default state.
        let showsClear = f.trailingAction != nil
        clearIcon.isHidden = !showsClear
        clearIcon.frame = CGRect(x: pill.maxX - 34, y: pill.midY - 12, width: 24, height: 24)
        trailingLabel.isHidden = f.trailingAction == nil
        trailingLabel.text = f.trailingAction
        trailingLabel.textColor = UIColor(cgColor: tokens.actionKeyFill.cgColor)
        trailingLabel.frame = CGRect(x: pill.maxX + 4, y: pill.minY, width: trailW - 14, height: pill.height)
        searchLabel.isHidden = false
        defer { placeCaret(field: f, in: searchLabel.frame) }
        let empty = f.text.isEmpty
        searchLabel.text = empty ? f.placeholder : f.text
        searchLabel.textColor = UIColor(cgColor: skin.stripLabel.cgColor).withAlphaComponent(empty ? 0.5 : 1)
        searchLabel.frame = CGRect(x: pill.minX + 34, y: pill.minY, width: pill.width - 34 - (showsClear ? 46 : 10), height: pill.height)
    }

    private func hideCaret() {
        caret.isHidden = true
        caret.removeAnimation(forKey: "blink")
    }

    /// The text cursor: after the query (or at the start of the placeholder), blinking unless Reduce Motion is on.
    private func placeCaret(field f: SearchField, in labelFrame: CGRect) {
        guard f.focused else { hideCaret(); return }
        let textW = f.text.isEmpty ? 0 : ceil((f.text as NSString).size(withAttributes: [.font: searchLabel.font as Any]).width)
        let x = labelFrame.minX + min(textW, labelFrame.width - 2) + (f.text.isEmpty ? 0 : 1)
        caret.frame = CGRect(x: x, y: labelFrame.midY - 10, width: 2, height: 20)
        caret.backgroundColor = tokens.actionKeyFill.cgColor
        caret.isHidden = false
        if caret.animation(forKey: "blink") == nil, !UIAccessibility.isReduceMotionEnabled {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [1, 1, 0, 0]
            a.keyTimes = [0, 0.5, 0.5, 1]
            a.duration = 1.0
            a.repeatCount = .infinity
            a.calculationMode = .discrete
            caret.add(a, forKey: "blink")
        }
    }

    private func layoutOverlay(w: CGFloat, h: CGFloat) {
        let label = UIColor(cgColor: tokens.keyLabel.cgColor)
        bannerLabel.isHidden = bannerText == nil
        bannerLabel.text = bannerText
        bannerLabel.textColor = label
        let areas = overlayRects(w: w)
        bannerLabel.frame = CGRect(x: areas.banner.minX + 6, y: 0, width: areas.banner.width - 12, height: h)
        bannerLabel.font = scaledFont(actionTitles.isEmpty ? 15 : 12)
        while actionLabels.count < actionTitles.count {
            let l = UILabel()
            l.textAlignment = .center
            l.font = scaledFont(14, weight: .medium)
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
            let cell = areas.actions.width / CGFloat(n)
            l.frame = CGRect(x: areas.actions.minX + CGFloat(i) * cell, y: 0, width: cell, height: h)
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
        let rects = slotRects(width: w, height: h)
        for (i, l) in slotLabels.enumerated() {
            // The system glass leaves ~16 pt above our view, so a centred strip looked top-heavy (about 34 pt above the
            // text, 22 below): draw the content in the upper part of the strip so both sides match.
            l.frame = CGRect(x: rects[i].minX, y: 0, width: rects[i].width, height: max(h - 2 * Self.upwardBias, 1))
            let newText = i < slotTexts.count ? slotTexts[i] : ""
            if l.text != newText, !UIAccessibility.isReduceMotionEnabled, alt == nil, !overlay, l.window != nil {
                // New words fade in instead of snapping (60 ms, only when something is already on screen).
                let t = CATransition(); t.type = .fade; t.duration = 0.06
                l.layer.add(t, forKey: "iboard.slotFade")
            }
            l.text = newText
            l.isHidden = alt != nil || overlay || (searchField != nil && (i == 0 || searchField!.wide))
            let on = alt == nil && !overlay && emphasizedSlots.contains(i) && !(l.text ?? "").isEmpty
            l.textColor = UIColor(cgColor: (on ? tokens.actionKeyLabel : skin.stripLabel).cgColor)
            l.font = scaledFont(16, weight: on || boldSlots.contains(i) ? .semibold : skin.fontWeight.uiWeight)
            let chip = chipLayers[i]
            chip.isHidden = skin.stripKind != .chips || alt != nil || overlay || on || (l.text ?? "").isEmpty
            chip.frame = l.frame.insetBy(dx: 3, dy: 1)
            chip.cornerRadius = min(chip.frame.height, chip.frame.width) / 3
            let e = emphasisLayers[i]
            e.isHidden = !on
            e.frame = l.frame.insetBy(dx: 4, dy: 1)
            e.cornerRadius = min(e.frame.height, e.frame.width) / 3
        }
        layoutSearchField(rects: rects, h: h, hidden: alt != nil || overlay)
        for (i, d) in dividers.enumerated() {
            // No divider across the fold band (between the two runs).
            d.frame = CGRect(x: rects[i].maxX - 0.25, y: (h - 2 * Self.upwardBias) * 0.075, width: 0.5, height: (h - 2 * Self.upwardBias) * 0.85)
            // Separators only between two filled slots (an empty strip stays clean).
            let filled = i + 1 < slotTexts.count && !slotTexts[i].isEmpty && !slotTexts[i + 1].isEmpty
            d.isHidden = alt != nil || overlay || (segments.count == 2 && i == 1) || !filled
        }
        guard let alt else { highlightLayer.isHidden = true; altPlate.isHidden = true; return }
        // Popup plate: the key colour with a soft shadow, rounded like the key popups; the chosen tile is a subtle tint.
        let row = alt.rowFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let plateH = min(h - 2 * Self.upwardBias, max(34, h - 14))
        altPlate.isHidden = false
        altPlate.frame = CGRect(x: row.minX - 3, y: (h - plateH) / 2 - Self.upwardBias / 2, width: row.width + 6, height: plateH)
        altPlate.cornerRadius = min(12, plateH / 3)
        altPlate.shadowPath = UIBezierPath(roundedRect: altPlate.bounds, cornerRadius: altPlate.cornerRadius).cgPath
        for (i, l) in altLabels.enumerated() where i < alt.options.count {
            let cell = alt.cellFrame(i).offsetBy(dx: -frame.minX, dy: -frame.minY)
            l.frame = cell.with(altPlate.frame.height).offsetBy(dx: 0, dy: altPlate.frame.minY)
            altIcons[i].frame = l.frame
            altIcons[i].tintColor = UIColor(cgColor: skin.stripLabel.cgColor)
            l.textColor = UIColor(cgColor: skin.stripLabel.cgColor)
        }
        if let hi = alt.highlighted {
            highlightLayer.isHidden = false
            let cell = altLabels[hi].frame.insetBy(dx: 2, dy: 3)
            highlightLayer.frame = cell
            highlightLayer.cornerRadius = min(8, min(cell.height, cell.width) / 3)
        } else {
            highlightLayer.isHidden = true
        }
    }
}

private extension CGRect {
    /// The same horizontal run with a full-height frame.
    func with(_ height: CGFloat) -> CGRect { CGRect(x: minX, y: 0, width: width, height: height) }
}
#endif
