#if canImport(UIKit)
import UIKit
import IBoardLayout
import IBoardTheme

public enum KeyTouchPhase: Sendable { case began, moved, ended, cancelled }

/// Renders a `KeyboardLayout` as a flat grid of `CALayer`s (D-24: UIKit + Core Animation, manual frames).
///
/// Rules this view follows (ROADMAP §6 touch budget, P-22, D-08):
/// - exactly one `CALayer` per key; the glyph is the layer's `contents` (a small cached bitmap), the tile is its
///   background colour with a continuous corner curve. No sublayers, no per-key views, no effect views.
/// - highlighting only swaps `backgroundColor` inside a transaction with actions disabled: no allocation, no
///   layout, no implicit animation on the touch path.
/// - no custom backdrop: the view is transparent and the system glass shows through (P-22).
/// - no preview balloon (D-08).
/// - touches are forwarded as plain values (`touchHandler`); the state machine lives elsewhere.
@MainActor
public final class KeyGridView: UIView {
    /// (phase, touch id, location in this view, `UITouch.timestamp` seconds). Called on the touch path.
    public var touchHandler: ((KeyTouchPhase, Int, CGPoint, TimeInterval) -> Void)?

    public private(set) var layout: KeyboardLayout?
    public private(set) var shift: ShiftState = .off
    /// `enablesReturnKeyAutomatically` with an empty field: the return key is drawn dimmed.
    public private(set) var returnKeyEnabled = true

    /// What to draw (colours, fonts, key decoration, trail). Native until the host installs the selected theme.
    public var skin: KeyboardSkin = .native(.light) {
        didSet { if skin != oldValue { applyTheme() } }
    }
    public var appearance: ThemeAppearance { skin.appearance }

    /// The swipe trail (M4-01), above all key layers. Style follows the theme (`trailStyle`).
    public let trail = SwipeTrailLayer()

    /// Faint secondary glyph (the up-flick character, M5-04) in the corner of each letter key. Off by default.
    public var showsFlickHints = false {
        didSet { if showsFlickHints != oldValue, let layout { apply(layout: layout) } }
    }

    /// Hides every key (the emoji panel covers the key area) while the view keeps receiving touches for the strip.
    public var keysHidden = false {
        didSet {
            guard keysHidden != oldValue else { return }
            invalidateAccessibility()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for l in keyLayers { l.isHidden = keysHidden }
            CATransaction.commit()
        }
    }

    private var tokens = NativeThemeTokens.light
    private var keyLayers: [CALayer] = []
    private var isAction: [Bool] = []
    private var highlighted: [Bool] = []
    private var fill = CGColor(gray: 1, alpha: 1)
    private var fillPressed = CGColor(gray: 0.8, alpha: 1)
    private var actionFill = CGColor(gray: 0, alpha: 1)
    private var actionFillPressed = CGColor(gray: 0, alpha: 1)
    private let glyphs = GlyphCache()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear // P-22: the system draws the backdrop
        applyThemeColors()
        layer.addSublayer(trail)
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: KeyGridView, _) in
            if let layout = view.layout { view.apply(layout: layout) }
        }
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Configuration

    /// Show `layout`. Reuses layers; cheap when only frames change.
    public func apply(layout new: KeyboardLayout, shift newShift: ShiftState? = nil) {
        if let newShift { shift = newShift }
        layout = new
        invalidateAccessibility()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        glyphs.configure(skin: skin, scale: scale, keyHeight: new.metrics.keyHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while keyLayers.count < new.keys.count {
            let l = CALayer()
            l.cornerCurve = .continuous
            l.contentsGravity = .center
            l.actions = ["contents": NSNull(), "backgroundColor": NSNull(), "bounds": NSNull(),
                         "position": NSNull(), "frame": NSNull()]
            layer.addSublayer(l)
            keyLayers.append(l)
        }
        while keyLayers.count > new.keys.count { keyLayers.removeLast().removeFromSuperlayer() }
        isAction = new.keys.map { Self.isActionKey($0.identity) }
        highlighted = [Bool](repeating: false, count: new.keys.count)
        for (i, key) in new.keys.enumerated() {
            let l = keyLayers[i]
            l.frame = snapped(key.frame, scale: scale)
            l.cornerRadius = new.metrics.cornerRadius * CGFloat(skin.cornerRadiusScale)
            decorate(l)
            l.contentsScale = scale
            l.backgroundColor = color(forKey: i, pressed: false)
            l.contents = glyphs.image(for: glyphSpec(for: key.identity))
            l.opacity = Self.dimmed(key.identity, returnKeyEnabled) ? 0.4 : 1
            l.isHidden = keysHidden
        }
        if shift == .capsLock, let i = new.keys.firstIndex(where: { $0.identity == .shift }) { updateCapsBar(on: keyLayers[i], locked: true) }
        CATransaction.commit()
    }

    private static func dimmed(_ identity: KeyIdentity, _ returnEnabled: Bool) -> Bool {
        if case .returnKey = identity { return !returnEnabled }
        return false
    }

    /// Dim or restore the return key (field trait `enablesReturnKeyAutomatically`).
    public func setReturnKeyEnabled(_ enabled: Bool) {
        guard enabled != returnKeyEnabled else { return }
        returnKeyEnabled = enabled
        invalidateAccessibility()
        guard let layout else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, key) in layout.keys.enumerated() {
            if case .returnKey = key.identity { keyLayers[i].opacity = enabled ? 1 : 0.4 }
        }
        CATransaction.commit()
    }

    /// Change shift without touching geometry: only the letter and shift glyphs are swapped.
    public func setShift(_ state: ShiftState) {
        guard state != shift, let layout else { shift = state; return }
        let old = shift
        shift = state
        invalidateAccessibility()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, key) in layout.keys.enumerated() {
            switch key.identity {
            case .letter: keyLayers[i].contents = glyphs.image(for: glyphSpec(for: key.identity))
            case .shift:
                keyLayers[i].contents = glyphs.image(for: glyphSpec(for: key.identity))
                keyLayers[i].backgroundColor = color(forKey: i, pressed: highlighted[i])
                updateCapsBar(on: keyLayers[i], locked: state == .capsLock)
                if state == .once, old == .off, !UIAccessibility.isReduceMotionEnabled {
                    // One small pulse when shift switches on by itself (sentence start).
                    let a = CAKeyframeAnimation(keyPath: "transform.scale")
                    a.values = [1, 1.07, 1]; a.keyTimes = [0, 0.4, 1]; a.duration = 0.22
                    keyLayers[i].add(a, forKey: "iboard.shiftPulse")
                }
            default: break
            }
        }
        CATransaction.commit()
    }

    /// Caps lock reads from the glyph AND an underline bar under it.
    private func updateCapsBar(on key: CALayer, locked: Bool) {
        if locked {
            capsBar.backgroundColor = tokens.keyLabel.cgColor
            capsBar.cornerRadius = 1.25
            capsBar.frame = CGRect(x: key.bounds.midX - 8, y: key.bounds.height - 9, width: 16, height: 2.5)
            if capsBar.superlayer !== key { key.addSublayer(capsBar) }
        } else {
            capsBar.removeFromSuperlayer()
        }
    }

    /// A pressed key shrinks a hair (0.96) on top of the colour change: the press reads even under a thumb.
    private static let pressedTransform = CATransform3DMakeScale(0.96, 0.96, 1)

    private let capsBar = CALayer()
    private var spaceHintShown = false

    /// Spacebar cursor drag: dim the letters and say what the space bar is doing.
    public func setCursorMode(_ on: Bool) {
        guard on != spaceHintShown, let layout else { return }
        spaceHintShown = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, key) in layout.keys.enumerated() {
            switch key.identity {
            case .letter: keyLayers[i].opacity = on ? 0.3 : 1
            case .space:
                keyLayers[i].contents = on ? glyphs.image(for: .text("‹ cursor ›", .function, onAction: false)) : nil
            default: break
            }
        }
        CATransaction.commit()
    }

    /// Touch-path call: swap one key's background colour. No allocation.
    public func setHighlighted(_ keyIndex: Int, _ on: Bool) {
        guard keyIndex >= 0, keyIndex < keyLayers.count, highlighted[keyIndex] != on else { return }
        highlighted[keyIndex] = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyLayers[keyIndex].backgroundColor = color(forKey: keyIndex, pressed: on)
        keyLayers[keyIndex].transform = on ? Self.pressedTransform : CATransform3DIdentity
        CATransaction.commit()
    }

    /// Release every highlight (layout swap, cancel).
    public func clearHighlights() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<highlighted.count where highlighted[i] {
            highlighted[i] = false
            keyLayers[i].backgroundColor = color(forKey: i, pressed: false)
            keyLayers[i].transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    // MARK: Layout / theme

    private func applyTheme() {
        applyThemeColors()
        if let layout { apply(layout: layout) }
    }

    private func applyThemeColors() {
        tokens = skin.tokens
        fill = tokens.keyFill.cgColor
        fillPressed = tokens.keyPressedFill.cgColor
        actionFill = tokens.actionKeyFill.cgColor
        actionFillPressed = tokens.actionKeyPressedFill.cgColor
        trail.trailStyle = skin.trail
    }

    /// Border / shadow of a key tile (themes only; Native has neither, so nothing is set and nothing is rasterised).
    private func decorate(_ l: CALayer) {
        if skin.keyBorderWidth > 0 {
            l.borderWidth = CGFloat(skin.keyBorderWidth)
            l.borderColor = skin.keyBorderColor.cgColor
        } else {
            l.borderWidth = 0
        }
        if skin.keyShadowColor.alpha > 0, skin.keyShadowRadius > 0 {
            l.shadowColor = skin.keyShadowColor.cgColor.copy(alpha: 1)
            l.shadowOpacity = Float(skin.keyShadowColor.alpha)
            l.shadowRadius = CGFloat(skin.keyShadowRadius)
            l.shadowOffset = CGSize(width: 0, height: skin.keyShadowOffsetY)
            // An explicit path keeps the shadow off the offscreen-rendering path.
            l.shadowPath = CGPath(roundedRect: l.bounds, cornerWidth: l.cornerRadius, cornerHeight: l.cornerRadius, transform: nil)
        } else {
            l.shadowOpacity = 0
            l.shadowPath = nil
        }
    }

    /// Shift key tile: neutral when off, the pressed grey while shift is on for one letter, blue-tinted for caps lock,
    /// so the state reads at a glance (the glyph alone is easy to miss).
    private static let capsLockFill = CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 0.38)

    private func color(forKey i: Int, pressed: Bool) -> CGColor {
        if let layout, i < layout.keys.count, case .shift = layout.keys[i].identity {
            switch shift {
            case .capsLock: return Self.capsLockFill
            case .once: return fillPressed
            case .off: break
            }
        }
        if isAction[i] { return pressed ? actionFillPressed : actionFill }
        return pressed ? fillPressed : fill
    }

    private func snapped(_ r: CGRect, scale: CGFloat) -> CGRect {
        func s(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let minX = s(r.minX), minY = s(r.minY)
        return CGRect(x: minX, y: minY, width: s(r.maxX) - minX, height: s(r.maxY) - minY)
    }

    // MARK: Glyph choice

    static func isActionKey(_ identity: KeyIdentity) -> Bool {
        guard case .returnKey(let kind) = identity else { return false }
        return ReturnKeyStyle.isProminent(kind)
    }

    /// The layout made the return key icon-width (narrower than a side key): draw its icon instead of the text label.
    private var narrowReturn: Bool {
        guard let layout, let ret = layout.keys.first(where: { if case .returnKey = $0.identity { return true } else { return false } })
        else { return false }
        return ret.frame.width < layout.metrics.sideKeyWidth * 0.8
    }

    func glyphSpec(for identity: KeyIdentity) -> GlyphSpec? {
        switch identity {
        case .letter(let s):
            if showsFlickHints, let hint = KeyFlick.hint(for: identity) {
                return .hinted(shift == .off ? s : s.uppercased(), hint: hint, upper: shift != .off)
            }
            return .text(shift == .off ? s : s.uppercased(), .letter(upper: shift != .off), onAction: false)
        case .symbol(let s): return .text(s, .symbol, onAction: false)
        case .domainSuffix(let s): return .text(s, .function, onAction: false)
        case .shift:
            return .symbol(shift == .capsLock ? "capslock.fill" : (shift == .once ? "shift.fill" : "shift"), onAction: false)
        case .delete: return .symbol("delete.left", onAction: false)
        case .layerSwitch(let k):
            switch k {
            case .numbers: return .text("123", .function, onAction: false)
            case .symbols: return .text("#+=", .function, onAction: false)
            default: return .text("ABC", .function, onAction: false)
            }
        case .space: return nil
        case .returnKey(let kind):
            if let symbol = kind.iconSymbol, narrowReturn {
                return .symbol(symbol, onAction: Self.isActionKey(identity))
            }
            if let label = ReturnKeyStyle.label(for: kind) {
                return .text(label, .function, onAction: Self.isActionKey(identity))
            }
            return .symbol("phone.fill", onAction: false)
        case .globe: return .symbol("globe", onAction: false)
        case .emoji: return .symbol("face.smiling", onAction: false)
        }
    }

    // MARK: VoiceOver (M13-01)

    private var a11yElements: [UIAccessibilityElement]?

    /// Drops the cached elements (layout, shift or return-key state changed). Cheap; rebuilt on demand by VoiceOver only.
    private func invalidateAccessibility() {
        guard a11yElements != nil else { return }
        a11yElements = nil
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    public override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    /// One element per key. The keys are plain layers (no views), so this is what VoiceOver and Voice Control see.
    public override var accessibilityElements: [Any]? {
        get {
            if keysHidden { return [] }
            if let a11yElements { return a11yElements }
            guard let layout else { return [] }
            let built: [UIAccessibilityElement] = layout.keys.map { key in
                let info = KeyAccessibility.info(for: key.identity, shift: shift, returnEnabled: returnKeyEnabled)
                let e = KeyElement(accessibilityContainer: self)
                e.accessibilityLabel = info.label
                e.accessibilityValue = info.value
                e.accessibilityTraits = [.keyboardKey]
                e.accessibilityFrameInContainerSpace = key.frame
                let center = CGPoint(x: key.frame.midX, y: key.frame.midY)
                e.onActivate = { [weak self] in self?.activateKey(at: center) }
                return e
            }
            a11yElements = built
            return built
        }
        set {}
    }

    /// A VoiceOver double tap: the same began / ended pair a finger would send, so the input machine is unchanged.
    private func activateKey(at point: CGPoint) {
        guard let touchHandler else { return }
        let id = -7
        let t = ProcessInfo.processInfo.systemUptime
        touchHandler(.began, id, point, t)
        touchHandler(.ended, id, point, t + 0.02)
    }

    private final class KeyElement: UIAccessibilityElement {
        var onActivate: (() -> Void)?
        override func accessibilityActivate() -> Bool { onActivate?(); return true }
    }

    // MARK: Touches (allocation-free path: values only)

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(.began, touches)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(.moved, touches)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(.ended, touches)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(.cancelled, touches)
    }

    @inline(__always)
    private func forward(_ phase: KeyTouchPhase, _ touches: Set<UITouch>) {
        guard let handler = touchHandler else { return }
        for t in touches {
            let id = Int(bitPattern: Unmanaged.passUnretained(t).toOpaque())
            handler(phase, id, t.location(in: self), t.timestamp)
        }
    }
}

extension ThemeColor {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

// MARK: - Glyph rendering

enum GlyphRole: Hashable {
    case letter(upper: Bool)
    case symbol
    case function
}

enum GlyphSpec: Hashable {
    case text(String, GlyphRole, onAction: Bool)
    /// A letter with its faint up-flick character in the top-right corner.
    case hinted(String, hint: String, upper: Bool)
    case symbol(String, onAction: Bool)
}

/// Renders each glyph once into a small bitmap (tight vertical box) and hands out the `CGImage`. Lives on the main
/// actor; never touched on a background queue. Cache is cleared whenever theme, scale or key height change.
@MainActor
final class GlyphCache {
    private var tokens = NativeThemeTokens.light
    private var weight = FontWeightToken.regular
    private var family: String?
    private var scale: CGFloat = 3
    private var keyHeight: CGFloat = 43
    private var images: [GlyphSpec: CGImage] = [:]

    /// Native baseline sits 28 pt below the tile top on a 43 pt tile (measured, native-metrics.json glyph table).
    private static let baselineRatio: CGFloat = 28.0 / 43.0

    func configure(skin: KeyboardSkin, scale: CGFloat, keyHeight: CGFloat) {
        if skin.tokens != tokens || skin.fontWeight != weight || skin.fontFamily != family
            || scale != self.scale || keyHeight != self.keyHeight {
            images.removeAll(keepingCapacity: true)
        }
        self.tokens = skin.tokens; self.weight = skin.fontWeight; self.family = skin.fontFamily
        self.scale = scale; self.keyHeight = keyHeight
    }

    /// SF Pro at the theme weight (Native: regular), or the theme's installed family when it exists.
    private func font(_ size: CGFloat) -> UIFont {
        if let family, let custom = UIFont(name: family, size: size) { return custom }
        return UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
    }

    func image(for spec: GlyphSpec?) -> CGImage? {
        guard let spec else { return nil }
        if let hit = images[spec] { return hit }
        let img = render(spec)
        images[spec] = img
        return img
    }

    private func render(_ spec: GlyphSpec) -> CGImage? {
        switch spec {
        case .text(let text, let role, let onAction):
            let size: CGFloat
            switch role {
            case .letter(let upper): size = upper ? tokens.uppercaseLetterFontSize : tokens.letterFontSize
            case .symbol: size = tokens.symbolFontSize
            case .function: size = tokens.functionLabelFontSize
            }
            let font = font(size)
            let color = UIColor(cgColor: (onAction ? tokens.actionKeyLabel : tokens.keyLabel).cgColor)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let textSize = (text as NSString).size(withAttributes: attrs)
            // Letters and symbols sit on the native baseline; function labels are centred.
            var offset: CGFloat = 0
            if case .function = role { offset = font.capHeight / 2 } else { offset = keyHeight * Self.baselineRatio - keyHeight / 2 }
            let ascent = font.ascender, descent = -font.descender
            let half = max(ascent + 1 - offset, descent + 1 + offset)
            let height = (2 * half).rounded(.up)
            let width = ceil(textSize.width) + 2
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
                let baselineY = height / 2 + offset
                (text as NSString).draw(at: CGPoint(x: (width - textSize.width) / 2, y: baselineY - ascent), withAttributes: attrs)
            }
            return image.cgImage
        case .hinted(let text, let hint, let upper):
            let font = font(upper ? tokens.uppercaseLetterFontSize : tokens.letterFontSize)
            let hintFont = UIFont.systemFont(ofSize: 9, weight: .regular)
            let color = UIColor(cgColor: tokens.keyLabel.cgColor)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let hintAttrs: [NSAttributedString.Key: Any] = [.font: hintFont, .foregroundColor: color.withAlphaComponent(0.4)]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let hintSize = (hint as NSString).size(withAttributes: hintAttrs)
            // Side margin of the centred letter is at least the hint's width, so the hint never overlaps the glyph.
            let width = ceil(textSize.width + hintSize.width * 2 + 6)
            let height = keyHeight // full key height so the hint can sit near the top edge
            let baselineY = keyHeight * Self.baselineRatio
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
                (text as NSString).draw(at: CGPoint(x: (width - textSize.width) / 2, y: baselineY - font.ascender), withAttributes: attrs)
                (hint as NSString).draw(at: CGPoint(x: width - hintSize.width - 1, y: 2), withAttributes: hintAttrs)
            }.cgImage
        case .symbol(let name, let onAction):
            let config = UIImage.SymbolConfiguration(pointSize: name == "globe" ? 20 : 19, weight: weight.symbolWeight)
            let color = UIColor(cgColor: (onAction ? tokens.actionKeyLabel : tokens.keyLabel).cgColor)
            guard let base = UIImage(systemName: name, withConfiguration: config) else { return nil }
            let tinted = base.withTintColor(color, renderingMode: .alwaysOriginal)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let size = tinted.size
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                tinted.draw(in: CGRect(origin: .zero, size: size))
            }.cgImage
        }
    }
}
extension FontWeightToken {
    var uiWeight: UIFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    var symbolWeight: UIImage.SymbolWeight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
#endif
