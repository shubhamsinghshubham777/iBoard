#if canImport(UIKit)
import UIKit

/// The emoji search results: one horizontally scrolling row of emoji sitting between the search field and the keys.
/// A tap reports the index of the item. Cells are reused; emoji are drawn at the panel's memory-safe size (26 pt, 2x).
@MainActor
public final class EmojiResultsRow: UIView {
    public struct Item: Equatable {
        public let text: String
        public let accessibilityName: String
        public init(text: String, accessibilityName: String) { self.text = text; self.accessibilityName = accessibilityName }
    }

    public var onSelect: ((Int) -> Void)?
    private var items: [Item] = []
    private let grid: UICollectionView
    private let emptyLabel = UILabel()
    private static let cellID = "emoji.result"

    public override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 2
        layout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        backgroundColor = EmojiPanelView.touchSurface
        grid.backgroundColor = EmojiPanelView.touchSurface
        grid.showsHorizontalScrollIndicator = false
        grid.alwaysBounceHorizontal = true
        grid.register(ResultCell.self, forCellWithReuseIdentifier: Self.cellID)
        grid.dataSource = self
        grid.delegate = self
        grid.frame = bounds
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(grid)
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.frame = bounds
        emptyLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Replaces the row. `emptyMessage` is shown when there is nothing to list.
    public func show(_ new: [Item], emptyMessage: String) {
        guard new != items else { return }
        items = new
        emptyLabel.text = emptyMessage
        emptyLabel.isHidden = !new.isEmpty
        grid.reloadData()
        grid.setContentOffset(.zero, animated: false)
    }
}

extension EmojiResultsRow: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    public func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    public func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: ip) as! ResultCell
        cell.configure(items[ip.item])
        return cell
    }

    public func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
        CGSize(width: 48, height: max(cv.bounds.height, 1))
    }

    public func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) { onSelect?(ip.item) }
}

private final class ResultCell: UICollectionViewCell {
    private let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 30)
        label.contentScaleFactor = 2
        label.frame = contentView.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: EmojiResultsRow.Item) {
        label.text = item.text
        accessibilityLabel = item.accessibilityName
    }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.12) : .clear; contentView.layer.cornerRadius = 8 }
    }
}
#endif
