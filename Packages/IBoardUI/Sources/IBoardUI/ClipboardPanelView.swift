#if canImport(UIKit)
import UIKit
import IBoardTheme

/// M9-03: the clipboard history panel. Replaces the key area (like the emoji panel). Tap a row pastes it; each row has
/// a pin button and a delete button; "Clear" empties the history (two taps: the second confirms, there are no alerts
/// in an extension). Text sizes follow Dynamic Type (capped). VoiceOver: rows are buttons with Pin / Delete custom
/// actions, and a rotor jumps between pinned items.
@MainActor
public final class ClipboardPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
    public var onPaste: ((String) -> Void)?
    public var onTogglePin: ((UUID, Bool) -> Void)?
    public var onDelete: ((UUID) -> Void)?
    public var onClearAll: (() -> Void)?
    public var onClose: (() -> Void)?

    public var skin: KeyboardSkin = .native(.light) { didSet { applySkin() } }

    public private(set) var model: ClipboardPanelModel
    private let table = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let footerLabel = UILabel()
    private let emptyLabel = UILabel()
    private var confirmingClear = false

    private static let headerHeight: CGFloat = 40

    public init(model: ClipboardPanelModel, skin: KeyboardSkin = .native(.light)) {
        self.model = model
        self.skin = skin
        super.init(frame: .zero)
        accessibilityIdentifier = "clipboard-panel"
        titleLabel.text = "Clipboard"
        titleLabel.accessibilityTraits = .header
        clearButton.setTitle("Clear", for: .normal)
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clearButton.accessibilityHint = "Removes all clipboard history, including pinned items. Double tap twice to confirm."
        doneButton.setTitle("Done", for: .normal)
        doneButton.accessibilityLabel = "Back to keyboard"
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        for b in [clearButton, doneButton] { b.titleLabel?.adjustsFontSizeToFitWidth = true; b.titleLabel?.minimumScaleFactor = 0.7 }
        table.dataSource = self
        table.delegate = self
        table.register(Cell.self, forCellReuseIdentifier: "row")
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 48
        footerLabel.numberOfLines = 2
        footerLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        for v in [table, titleLabel, clearButton, doneButton, footerLabel, emptyLabel] { addSubview(v) }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: ClipboardPanelView, _) in
            self.applyFonts()
            self.table.reloadData()
            self.setNeedsLayout()
        }
        applySkin()
        applyFonts()
        refresh()
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Content

    public func update(_ new: ClipboardPanelModel) {
        let animate = !UIAccessibility.isReduceMotionEnabled && window != nil && new.rows.count != model.rows.count
        model = new
        confirmingClear = false
        refresh()
        if animate {
            UIView.transition(with: table, duration: 0.15, options: .transitionCrossDissolve) { self.table.reloadData() }
        } else {
            table.reloadData()
        }
    }

    private func refresh() {
        emptyLabel.text = model.emptyMessage
        emptyLabel.isHidden = !model.rows.isEmpty
        table.isHidden = model.rows.isEmpty
        footerLabel.text = model.footer
        clearButton.setTitle(confirmingClear ? "Tap again" : "Clear", for: .normal)
        clearButton.isEnabled = model.canClear
        clearButton.accessibilityLabel = confirmingClear ? "Confirm clear history" : "Clear history"
        setNeedsLayout()
    }

    private func scaled(_ base: CGFloat, weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body) -> UIFont {
        let m = UIFontMetrics(forTextStyle: style)
        let size = StripTypeScale.size(base: base, scaled: m.scaledValue(for: base, compatibleWith: traitCollection), maxFactor: 1.6)
        return .systemFont(ofSize: size, weight: weight)
    }

    private func applyFonts() {
        titleLabel.font = scaled(16, weight: .semibold)
        clearButton.titleLabel?.font = scaled(15)
        doneButton.titleLabel?.font = scaled(15, weight: .semibold)
        footerLabel.font = scaled(11, style: .caption2)
        emptyLabel.font = scaled(14)
    }

    private func applySkin() {
        let label = UIColor(cgColor: skin.stripLabel.cgColor)
        let accent = UIColor(cgColor: skin.tokens.actionKeyFill.cgColor)
        titleLabel.textColor = label
        footerLabel.textColor = label.withAlphaComponent(0.55)
        emptyLabel.textColor = label.withAlphaComponent(0.6)
        clearButton.tintColor = accent
        doneButton.tintColor = accent
        table.reloadData()
    }

    // MARK: Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let header = max(Self.headerHeight, ceil(titleLabel.font.lineHeight) + 16)
        let btnW: CGFloat = min(96, w * 0.25)
        titleLabel.frame = CGRect(x: 16, y: 0, width: max(0, w - 32 - 2 * btnW), height: header)
        doneButton.frame = CGRect(x: w - btnW - 8, y: 0, width: btnW, height: header)
        clearButton.frame = CGRect(x: w - 2 * btnW - 8, y: 0, width: btnW, height: header)
        let footerH = ceil(footerLabel.font.lineHeight) * 2 + 4
        footerLabel.frame = CGRect(x: 16, y: bounds.height - footerH, width: max(0, w - 32), height: footerH)
        let top = header
        table.frame = CGRect(x: 0, y: top, width: w, height: max(0, bounds.height - top - footerH))
        emptyLabel.frame = table.frame.insetBy(dx: 24, dy: 0)
    }

    // MARK: Actions

    @objc private func clearTapped() {
        if confirmingClear { confirmingClear = false; onClearAll?() }
        else { confirmingClear = true; refresh() }
    }

    @objc private func doneTapped() { onClose?() }

    // MARK: Table

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { model.rows.count }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! Cell
        let row = model.rows[indexPath.row]
        cell.configure(row: row, skin: skin, font: scaled(15), small: scaled(11, style: .caption2))
        cell.onPin = { [weak self] in self?.onTogglePin?(row.id, !row.pinned) }
        cell.onDelete = { [weak self] in self?.onDelete?(row.id) }
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        onPaste?(model.rows[indexPath.row].text)
    }

    // MARK: VoiceOver rotor

    public override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
        get {
            let pinned = UIAccessibilityCustomRotor(name: "Pinned items") { [weak self] predicate in
                guard let self else { return nil }
                let rows = self.model.rows
                let indices = rows.indices.filter { rows[$0].pinned }
                guard !indices.isEmpty else { return nil }
                var current = -1
                if let cell = predicate.currentItem.targetElement as? Cell, let ip = self.table.indexPath(for: cell) { current = ip.row }
                let forward = predicate.searchDirection == .next
                let target = forward ? indices.first { $0 > current } : indices.last { $0 < current }
                guard let t = target, let cell = self.table.cellForRow(at: IndexPath(row: t, section: 0)) else { return nil }
                return UIAccessibilityCustomRotorItemResult(targetElement: cell, targetRange: nil)
            }
            return [pinned]
        }
        set {}
    }

    // MARK: Cell

    private final class Cell: UITableViewCell {
        var onPin: (() -> Void)?
        var onDelete: (() -> Void)?
        private let text = UILabel()
        private let meta = UILabel()
        private let pin = UIButton(type: .system)
        private let del = UIButton(type: .system)
        private let card = UIView()
        private var pinned = false

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            selectionStyle = .none
            card.layer.cornerRadius = 10
            card.layer.cornerCurve = .continuous
            contentView.addSubview(card)
            text.numberOfLines = 2
            text.lineBreakMode = .byTruncatingTail
            meta.numberOfLines = 1
            pin.addTarget(self, action: #selector(pinTapped), for: .touchUpInside)
            del.addTarget(self, action: #selector(delTapped), for: .touchUpInside)
            del.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
            for v in [text, meta, pin, del] { card.addSubview(v) }
            // The row is one VoiceOver element; the buttons are reachable as custom actions.
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        @objc private func pinTapped() { onPin?() }
        @objc private func delTapped() { onDelete?() }

        func configure(row: ClipboardPanelModel.Row, skin: KeyboardSkin, font: UIFont, small: UIFont) {
            pinned = row.pinned
            let label = UIColor(cgColor: skin.stripLabel.cgColor)
            let accent = UIColor(cgColor: skin.tokens.actionKeyFill.cgColor)
            card.backgroundColor = UIColor(cgColor: skin.tokens.keyFill.cgColor)
            text.font = font
            text.textColor = label
            text.text = row.preview
            meta.font = small
            meta.textColor = label.withAlphaComponent(0.55)
            meta.text = row.isCode ? "Code · " + row.age : row.age
            pin.setImage(UIImage(systemName: row.pinned ? "pin.fill" : "pin"), for: .normal)
            pin.tintColor = row.pinned ? accent : label.withAlphaComponent(0.55)
            del.tintColor = label.withAlphaComponent(0.55)
            pin.accessibilityLabel = row.pinned ? "Unpin" : "Pin"
            del.accessibilityLabel = "Delete"
            accessibilityLabel = row.accessibilityLabel
            accessibilityHint = "Pastes this item"
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: row.pinned ? "Unpin" : "Pin") { [weak self] _ in self?.onPin?(); return true },
                UIAccessibilityCustomAction(name: "Delete") { [weak self] _ in self?.onDelete?(); return true },
            ]
            setNeedsLayout()
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            let inner = layoutWidths(in: size.width)
            let t = text.sizeThatFits(CGSize(width: inner.text, height: .greatestFiniteMagnitude)).height
            return CGSize(width: size.width, height: max(48, t + ceil(meta.font.lineHeight) + 16) + 6)
        }

        override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority h: UILayoutPriority,
                                              verticalFittingPriority v: UILayoutPriority) -> CGSize {
            sizeThatFits(CGSize(width: targetSize.width, height: 0))
        }

        private func layoutWidths(in w: CGFloat) -> (text: CGFloat, buttons: CGFloat) {
            let buttons: CGFloat = 44 * 2
            return (max(0, w - 16 - 12 - buttons - 8), buttons)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            card.frame = CGRect(x: 8, y: 3, width: bounds.width - 16, height: bounds.height - 6)
            let btnW: CGFloat = 44
            del.frame = CGRect(x: card.bounds.width - btnW, y: 0, width: btnW, height: card.bounds.height)
            pin.frame = CGRect(x: card.bounds.width - 2 * btnW, y: 0, width: btnW, height: card.bounds.height)
            let tw = card.bounds.width - 12 - 2 * btnW
            let th = text.sizeThatFits(CGSize(width: tw, height: .greatestFiniteMagnitude)).height
            let mh = ceil(meta.font.lineHeight)
            let top = max(6, (card.bounds.height - th - mh) / 2)
            text.frame = CGRect(x: 12, y: top, width: tw, height: th)
            meta.frame = CGRect(x: 12, y: top + th, width: tw, height: mh)
        }
    }
}
#endif
