#if canImport(UIKit)
import UIKit

/// The emoji panel's bottom bar: ABC on the left and the kaomoji tab on the right stay put; the category icons between
/// them scroll horizontally. Icons are the category emoji; the current one is full strength on a soft tile. Selection follows the list's scroll position.
@MainActor
final class EmojiCategoryBar: UIView {
    typealias Tab = EmojiPanelView.Tab

    struct Chip {
        let tab: Tab
        let symbol: String
        let label: String
    }

    static let chips: [Chip] = [
        Chip(tab: .recents, symbol: "🕘", label: "Recents"),
        Chip(tab: .group(0), symbol: "😀", label: "Smileys and emotion"),
        Chip(tab: .group(1), symbol: "🧑", label: "People and body"),
        Chip(tab: .group(2), symbol: "🐻", label: "Animals and nature"),
        Chip(tab: .group(3), symbol: "🍔", label: "Food and drink"),
        Chip(tab: .group(4), symbol: "🚗", label: "Travel and places"),
        Chip(tab: .group(5), symbol: "⚽", label: "Activities"),
        Chip(tab: .group(6), symbol: "💡", label: "Objects"),
        Chip(tab: .group(7), symbol: "🔣", label: "Symbols"),
        Chip(tab: .group(8), symbol: "🏳️", label: "Flags"),
    ]

    static let height: CGFloat = 44
    private static let fixedWidth: CGFloat = 60
    private static let chipWidth: CGFloat = 50

    var onClose: (() -> Void)?
    var onSelect: ((Tab) -> Void)?

    private(set) var selected: Tab?
    private let close = UIButton(type: .system)
    private let kaomoji = UIButton(type: .system)
    private let list: UICollectionView
    /// Fixed container that carries the edge-fade mask: a mask on the scroll view itself would move with its offset.
    private let listHost = UIView()
    private let fade = CAGradientLayer()
    private let separators = [UIView(), UIView()]

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        list = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)

        close.setTitle("ABC", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        close.accessibilityLabel = "Back to keyboard"
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        kaomoji.setTitle("^_^", for: .normal)
        kaomoji.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        kaomoji.accessibilityLabel = "Kaomoji"
        kaomoji.addAction(UIAction { [weak self] _ in self?.onSelect?(.kaomoji) }, for: .touchUpInside)

        backgroundColor = EmojiPanelView.touchSurface
        listHost.backgroundColor = EmojiPanelView.touchSurface
        list.backgroundColor = EmojiPanelView.touchSurface
        list.showsHorizontalScrollIndicator = false
        list.alwaysBounceHorizontal = true
        list.register(CategoryCell.self, forCellWithReuseIdentifier: "chip")
        list.dataSource = self
        list.delegate = self
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        listHost.layer.mask = fade
        listHost.addSubview(list)

        for v in separators { v.backgroundColor = UIColor.separator; addSubview(v) }
        addSubview(listHost)
        addSubview(close)
        addSubview(kaomoji)
        setSelected(nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height, fw = Self.fixedWidth
        close.frame = CGRect(x: 0, y: 0, width: fw, height: h)
        kaomoji.frame = CGRect(x: w - fw, y: 0, width: fw, height: h)
        listHost.frame = CGRect(x: fw, y: 0, width: max(w - 2 * fw, 0), height: h)
        list.frame = listHost.bounds
        separators[0].frame = CGRect(x: fw, y: (h - 20) / 2, width: 0.5, height: 20)
        separators[1].frame = CGRect(x: w - fw, y: (h - 20) / 2, width: 0.5, height: 20)
        let edge = listHost.bounds.width > 0 ? min(0.08, 14 / listHost.bounds.width) : 0
        fade.frame = listHost.bounds
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
    }

    /// Marks the current category (nil: none, e.g. search results) and keeps it in view.
    func setSelected(_ tab: Tab?, animated: Bool = false) {
        selected = tab
        for case let cell as CategoryCell in list.visibleCells {
            if let ip = list.indexPath(for: cell) { cell.apply(Self.chips[ip.item], selected: Self.chips[ip.item].tab == tab) }
        }
        kaomoji.setTitleColor(tab == .kaomoji ? .label : .secondaryLabel, for: .normal)
        kaomoji.backgroundColor = tab == .kaomoji ? UIColor.label.withAlphaComponent(0.14) : .clear
        kaomoji.layer.cornerRadius = 12
        if let i = Self.chips.firstIndex(where: { $0.tab == tab }), list.bounds.width > 0 {
            // Centre the chip from known geometry (insets 8, chip 50, gap 4); no dependency on a finished layout.
            let content = 16 + CGFloat(Self.chips.count) * Self.chipWidth + CGFloat(Self.chips.count - 1) * 4
            let centre = 8 + CGFloat(i) * (Self.chipWidth + 4) + Self.chipWidth / 2
            let x = min(max(centre - list.bounds.width / 2, 0), max(content - list.bounds.width, 0))
            if abs(list.contentOffset.x - x) > 0.5 { list.setContentOffset(CGPoint(x: x, y: 0), animated: animated && !UIAccessibility.isReduceMotionEnabled) }
        }
    }
}

extension EmojiCategoryBar: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { Self.chips.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "chip", for: ip) as! CategoryCell
        let chip = Self.chips[ip.item]
        cell.apply(chip, selected: chip.tab == selected)
        return cell
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
        CGSize(width: Self.chipWidth, height: Self.height - 8)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) { onSelect?(Self.chips[ip.item].tab) }
}

private final class CategoryCell: UICollectionViewCell {
    private let icon = UILabel()
    private let tile = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        tile.layer.cornerRadius = 12
        tile.layer.cornerCurve = .continuous
        tile.frame = contentView.bounds
        tile.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(tile)
        icon.textAlignment = .center
        icon.font = .systemFont(ofSize: 25)
        icon.frame = contentView.bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(icon)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ chip: EmojiCategoryBar.Chip, selected: Bool) {
        icon.text = chip.symbol
        icon.alpha = selected ? 1 : 0.55
        tile.backgroundColor = selected ? UIColor.label.withAlphaComponent(0.14) : .clear
        accessibilityLabel = chip.label
        accessibilityTraits = selected ? [.button, .selected] : .button
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
#endif
