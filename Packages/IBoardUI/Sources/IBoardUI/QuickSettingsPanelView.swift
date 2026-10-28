#if canImport(UIKit)
import UIKit
import IBoardCore
import IBoardTheme

/// What the Quick Settings panel shows. Plain values, no typed text.
public struct QuickSettingsState: Equatable, Sendable {
    public var hapticPack: HapticPack
    public var numberRow: Bool
    public var autocorrect: AutocorrectLevel
    public var swipeTyping: Bool
    public var incognito: Bool
    public var landscapeSideKeys: Bool
    public var hasFullAccess: Bool

    public init(settings: IBoardSettings, incognito: Bool, hasFullAccess: Bool) {
        hapticPack = settings.hapticPack
        numberRow = settings.numberRow
        autocorrect = settings.autocorrect
        swipeTyping = settings.swipeTyping
        self.incognito = incognito
        landscapeSideKeys = settings.landscapeSideKeys
        self.hasFullAccess = hasFullAccess
    }

    public static func hapticTitle(_ p: HapticPack) -> String {
        switch p {
        case .standard: "Standard"
        case .soft: "Soft"
        case .crisp: "Crisp"
        case .lettersOnly: "Letters"
        }
    }

    public static func autocorrectTitle(_ l: AutocorrectLevel) -> String {
        switch l {
        case .off: "Off"
        case .conservative: "Gentle"
        case .balanced: "Balanced"
        case .aggressive: "Bold"
        }
    }
}

/// In-keyboard Quick Settings (opened from the emoji key's long press). Replaces the key area like the emoji and
/// clipboard panels, is created on open and dropped on close, and holds only a few small views (no table, no images
/// beyond one SF Symbol). Dynamic Type is honoured (capped, the content scrolls), every control has a VoiceOver label
/// and value, and nothing animates, so Reduce Motion needs no special case.
@MainActor
public final class QuickSettingsPanelView: UIView {
    public private(set) var state: QuickSettingsState
    public var skin: KeyboardSkin = .native(.light) { didSet { applySkin() } }

    public var onEdit: ((QuickSettingsEdit) -> Void)?
    public var onIncognito: ((Bool) -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// Opens the iBoard app on its Settings screen (the full settings, not only these quick ones).
    public var onOpenAppSettings: (() -> Void)?
    public var onClose: (() -> Void)?

    private let titleLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var cards: [UIView] = []
    private var captions: [UILabel] = []
    private var rowLabels: [UILabel] = []
    private var switches: [UISwitch] = []
    private var segmented: [UISegmentedControl] = []
    private let settingsRow = UIButton(type: .system)
    private let appSettingsRow = UIButton(type: .system)
    private let footer = UILabel()
    private let hapticSegment = UISegmentedControl(items: HapticPack.allCases.map { QuickSettingsState.hapticTitle($0) })
    private let autocorrectSegment = UISegmentedControl(items: AutocorrectLevel.allCases.map { QuickSettingsState.autocorrectTitle($0) })
    private let numberRowSwitch = UISwitch()
    private let swipeSwitch = UISwitch()
    private let incognitoSwitch = UISwitch()
    private let sideKeysSwitch = UISwitch()

    private static let headerHeight: CGFloat = 40

    public init(state: QuickSettingsState, skin: KeyboardSkin = .native(.light)) {
        self.state = state
        self.skin = skin
        super.init(frame: .zero)
        accessibilityIdentifier = "quick-settings-panel"
        titleLabel.text = "Quick settings"
        titleLabel.accessibilityTraits = .header
        doneButton.setTitle("Done", for: .normal)
        doneButton.accessibilityLabel = "Back to keyboard"
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.titleLabel?.adjustsFontSizeToFitWidth = true
        doneButton.titleLabel?.minimumScaleFactor = 0.7

        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 12, right: 12)
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        for v in [scroll, titleLabel, doneButton] { addSubview(v) }

        addSegmentRow("Haptic pack", hapticSegment, #selector(hapticChanged))
        addSegmentRow("Autocorrect", autocorrectSegment, #selector(autocorrectChanged))
        addSwitchRow("Number row", numberRowSwitch, #selector(numberRowChanged))
        addSwitchRow("Swipe typing", swipeSwitch, #selector(swipeChanged))
        addSwitchRow("Incognito", incognitoSwitch, #selector(incognitoChanged))
        addSwitchRow("Landscape side keys", sideKeysSwitch, #selector(sideKeysChanged))

        var appCfg = UIButton.Configuration.plain()
        appCfg.image = UIImage(systemName: "slider.horizontal.3")
        appCfg.imagePadding = 8
        appCfg.title = "All iBoard settings"
        appCfg.titleLineBreakMode = .byWordWrapping
        appCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        appSettingsRow.configuration = appCfg
        appSettingsRow.contentHorizontalAlignment = .leading
        appSettingsRow.accessibilityLabel = "All iBoard settings"
        appSettingsRow.accessibilityHint = "Opens the iBoard app on its Settings screen"
        appSettingsRow.addTarget(self, action: #selector(openAppSettingsTapped), for: .touchUpInside)
        addCard(appSettingsRow)

        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "gearshape")
        cfg.imagePadding = 8
        cfg.title = "Open iOS Keyboard Settings (Full Access)"
        cfg.titleLineBreakMode = .byWordWrapping
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        settingsRow.configuration = cfg
        settingsRow.contentHorizontalAlignment = .leading
        settingsRow.accessibilityLabel = "Open iOS Keyboard Settings"
        settingsRow.accessibilityHint = "Opens the Settings app, where Full Access can be turned on"
        settingsRow.addTarget(self, action: #selector(openSettingsTapped), for: .touchUpInside)
        addCard(settingsRow)

        footer.numberOfLines = 0
        footer.textAlignment = .center
        stack.addArrangedSubview(footer)

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: QuickSettingsPanelView, _) in
            self.applyFonts()
            self.setNeedsLayout()
        }
        applySkin()
        applyFonts()
        refresh()
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Rows

    private func addCard(_ content: UIView, insets: UIEdgeInsets = .zero) {
        let card = UIView()
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -insets.bottom),
        ])
        cards.append(card)
        stack.addArrangedSubview(card)
    }

    private func addSwitchRow(_ title: String, _ sw: UISwitch, _ action: Selector) {
        let label = UILabel()
        label.text = title
        label.numberOfLines = 0
        rowLabels.append(label)
        sw.addTarget(self, action: action, for: .valueChanged)
        sw.accessibilityLabel = title
        switches.append(sw)
        let row = UIStackView(arrangedSubviews: [label, sw])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        sw.setContentHuggingPriority(.required, for: .horizontal)
        sw.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 31).isActive = true
        addCard(row, insets: UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12))
    }

    private func addSegmentRow(_ title: String, _ seg: UISegmentedControl, _ action: Selector) {
        let label = UILabel()
        label.text = title
        rowLabels.append(label)
        seg.addTarget(self, action: action, for: .valueChanged)
        seg.accessibilityLabel = title
        segmented.append(seg)
        let col = UIStackView(arrangedSubviews: [label, seg])
        col.axis = .vertical
        col.spacing = 6
        addCard(col, insets: UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
    }

    // MARK: State

    public func update(_ new: QuickSettingsState) {
        state = new
        refresh()
    }

    private func refresh() {
        hapticSegment.selectedSegmentIndex = HapticPack.allCases.firstIndex(of: state.hapticPack) ?? 0
        autocorrectSegment.selectedSegmentIndex = AutocorrectLevel.allCases.firstIndex(of: state.autocorrect) ?? 0
        numberRowSwitch.isOn = state.numberRow
        swipeSwitch.isOn = state.swipeTyping
        incognitoSwitch.isOn = state.incognito
        sideKeysSwitch.isOn = state.landscapeSideKeys
        // Haptics are only felt with Full Access (P-23): say so instead of hiding the choice.
        hapticSegment.accessibilityValue = QuickSettingsState.hapticTitle(state.hapticPack)
            + (state.hasFullAccess ? "" : ", felt only with Full Access")
        autocorrectSegment.accessibilityValue = QuickSettingsState.autocorrectTitle(state.autocorrect)
        footer.text = state.hasFullAccess
            ? "Changes are saved and shared with the iBoard app."
            : "Changes apply to this keyboard only. Turn on Full Access to share them with the app and feel haptics."
        applySkin()
    }

    @objc private func hapticChanged() {
        let i = hapticSegment.selectedSegmentIndex
        guard HapticPack.allCases.indices.contains(i) else { return }
        emit(.hapticPack(HapticPack.allCases[i]))
    }

    @objc private func autocorrectChanged() {
        let i = autocorrectSegment.selectedSegmentIndex
        guard AutocorrectLevel.allCases.indices.contains(i) else { return }
        emit(.autocorrect(AutocorrectLevel.allCases[i]))
    }

    @objc private func numberRowChanged() { emit(.numberRow(numberRowSwitch.isOn)) }
    @objc private func swipeChanged() { emit(.swipeTyping(swipeSwitch.isOn)) }
    @objc private func sideKeysChanged() { emit(.landscapeSideKeys(sideKeysSwitch.isOn)) }
    @objc private func incognitoChanged() {
        state.incognito = incognitoSwitch.isOn
        onIncognito?(incognitoSwitch.isOn)
    }
    @objc private func openSettingsTapped() { onOpenSettings?() }
    @objc private func openAppSettingsTapped() { onOpenAppSettings?() }
    @objc private func doneTapped() { onClose?() }

    private func emit(_ edit: QuickSettingsEdit) {
        switch edit {
        case .hapticPack(let v): state.hapticPack = v
        case .numberRow(let v): state.numberRow = v
        case .autocorrect(let v): state.autocorrect = v
        case .swipeTyping(let v): state.swipeTyping = v
        case .landscapeSideKeys(let v): state.landscapeSideKeys = v
        }
        onEdit?(edit)
    }

    // MARK: Look

    private func applySkin() {
        let label = UIColor(cgColor: skin.stripLabel.cgColor)
        let accent = UIColor(cgColor: skin.tokens.actionKeyFill.cgColor)
        let card = UIColor(cgColor: skin.tokens.keyFill.cgColor)
        titleLabel.textColor = label
        doneButton.tintColor = accent
        footer.textColor = label.withAlphaComponent(0.55)
        for l in rowLabels { l.textColor = label }
        for c in cards { c.backgroundColor = card }
        for s in switches { s.onTintColor = accent }
        for s in segmented { s.selectedSegmentTintColor = accent.withAlphaComponent(0.9) }
        settingsRow.tintColor = accent
        appSettingsRow.tintColor = accent
        for s in segmented {
            s.setTitleTextAttributes([.foregroundColor: label], for: .normal)
            s.setTitleTextAttributes([.foregroundColor: UIColor(cgColor: skin.tokens.actionKeyLabel.cgColor)], for: .selected)
        }
    }

    /// Dynamic Type, capped at 24 pt so a row never outgrows the keyboard (the content scrolls anyway).
    private func scaled(_ base: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let m = UIFontMetrics(forTextStyle: .body)
        return .systemFont(ofSize: m.scaledValue(for: base, compatibleWith: traitCollection).clamped(to: base...24), weight: weight)
    }

    private func applyFonts() {
        titleLabel.font = scaled(17, weight: .semibold)
        doneButton.titleLabel?.font = scaled(17, weight: .semibold)
        for l in rowLabels { l.font = scaled(16) }
        footer.font = scaled(12)
        let seg = UIFont.systemFont(ofSize: min(scaled(13).pointSize, 16)) // four segments share the width
        for s in segmented { s.setTitleTextAttributes([.font: seg], for: .normal); s.setTitleTextAttributes([.font: seg], for: .selected) }
        appSettingsRow.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [font = scaled(15)] in
            var a = $0; a.font = font; return a
        }
        settingsRow.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [font = scaled(15)] in
            var a = $0; a.font = font; return a
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let header = max(Self.headerHeight, ceil(titleLabel.font.lineHeight) + 16)
        let btnW: CGFloat = min(96, w * 0.25)
        titleLabel.frame = CGRect(x: 16, y: 0, width: max(0, w - 32 - btnW), height: header)
        doneButton.frame = CGRect(x: w - btnW - 8, y: 0, width: btnW, height: header)
        scroll.frame = CGRect(x: 0, y: header, width: w, height: max(0, bounds.height - header))
    }

}

private extension CGFloat {
    func clamped(to r: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}
#endif
