#if canImport(UIKit)
import UIKit

/// The emoji panel: category bar, lazily-cell'd grid, recents, skin-tone memory, kaomoji tab.
/// Memory (F8, P-21): the catalog is loaded when the panel enters a window and dropped when it leaves
/// or on `didReceiveMemoryWarning()`; cells are reused (a handful of UILabels), never one view per emoji.
/// NOT TESTED on device/simulator: compiled only. See docs/EMOJI_DATA.md for the integration API.
@MainActor
public final class EmojiPanelView: UIView {
    public enum Tab: Equatable {
        case recents
        case group(Int)
        case kaomoji
        case search
    }

    private struct Item {
        let text: String
        let entryIndex: Int?
        let accessibilityName: String
    }

    // Integration API
    public var onInsert: ((String) -> Void)?
    public var onPreferencesChange: ((EmojiPreferences) -> Void)?
    public var onClose: (() -> Void)?
    public private(set) var preferences: EmojiPreferences

    private let store: EmojiStore
    private var catalog: EmojiCatalog?
    private var items: [Item] = []
    private(set) public var tab: Tab = .recents
    private let grid: UICollectionView
    private let bar = UIStackView()
    private var tabButtons: [(Tab, UIButton)] = []

    private static let cellID = "emoji.cell"
    private static let groupGlyphs = ["😀", "🧑", "🐻", "🍔", "🚗", "⚽", "💡", "🔣", "🏳️"]

    public init(store: EmojiStore = EmojiStore(), preferences: EmojiPreferences = EmojiPreferences()) {
        self.store = store
        self.preferences = preferences
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func configure() {
        grid.backgroundColor = .clear
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: Self.cellID)
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.addInteraction(UIContextMenuInteraction(delegate: self))
        grid.translatesAutoresizingMaskIntoConstraints = false

        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.translatesAutoresizingMaskIntoConstraints = false
        let close = UIButton(type: .system)
        close.setTitle("ABC", for: .normal)
        close.accessibilityLabel = "Back to keyboard"
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        bar.addArrangedSubview(close)
        func addTab(_ t: Tab, _ glyph: String, _ label: String) {
            let b = UIButton(type: .system)
            b.setTitle(glyph, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 18)
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.accessibilityLabel = label
            b.addAction(UIAction { [weak self] _ in self?.select(t) }, for: .touchUpInside)
            bar.addArrangedSubview(b)
            tabButtons.append((t, b))
        }
        addTab(.recents, "🕘", "Recents")
        for (i, g) in Self.groupGlyphs.enumerated() { addTab(.group(i), g, "Category \(i + 1)") }
        addTab(.kaomoji, "^_^", "Kaomoji")

        addSubview(grid)
        addSubview(bar)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    // MARK: Lifecycle (memory)

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { open() } else { releaseCaches() }
    }

    /// Loads data and shows the current tab (recents if non-empty, else the first group).
    public func open() {
        catalog = store.catalog()
        if tab == .recents && preferences.recents.items.isEmpty { tab = .group(0) }
        select(tab)
    }

    /// Drop everything that can be rebuilt: catalog, item arrays, visible cells.
    public func releaseCaches() {
        items = []
        catalog = nil
        store.dropCaches()
        grid.reloadData()
    }

    /// Call from the keyboard view controller's didReceiveMemoryWarning.
    public func didReceiveMemoryWarning() { releaseCaches() }

    // MARK: Tabs

    public func select(_ t: Tab) {
        tab = t
        if catalog == nil { catalog = store.catalog() }
        switch t {
        case .recents:
            let c = catalog
            items = preferences.recents.items.map { s in
                let idx = c?.entries.firstIndex { $0.emoji == s || $0.tones.contains(s) }
                return Item(text: s, entryIndex: idx, accessibilityName: idx.flatMap { c?.entries[$0].name } ?? s)
            }
        case .group(let g):
            if let c = catalog {
                items = c.indices(inGroup: g).map { i in
                    let e = c.entries[i]
                    return Item(text: preferences.skinTones.resolve(e), entryIndex: i, accessibilityName: e.name)
                }
            } else { items = [] }
        case .kaomoji:
            items = Kaomoji.categories.flatMap(\.items).map { Item(text: $0, entryIndex: nil, accessibilityName: $0) }
        case .search:
            break // items set by `showSearchResults`
        }
        for (tt, b) in tabButtons { b.isSelected = tt == t; b.alpha = tt == t ? 1 : 0.55 }
        (grid.collectionViewLayout as? UICollectionViewFlowLayout)?.invalidateLayout()
        grid.reloadData()
        grid.setContentOffset(.zero, animated: false)
    }

    /// Shows search results (entry indices into the catalog, ranked) in the grid.
    public func showSearchResults(_ entryIndices: [Int]) {
        guard let c = catalog ?? store.catalog() else { return }
        catalog = c
        tab = .search
        items = entryIndices.compactMap { i in
            guard c.entries.indices.contains(i) else { return nil }
            let e = c.entries[i]
            return Item(text: preferences.skinTones.resolve(e), entryIndex: i, accessibilityName: e.name)
        }
        for (_, b) in tabButtons { b.isSelected = false; b.alpha = 0.55 }
        grid.reloadData()
    }

    fileprivate func commit(_ p: EmojiPreferences) {
        preferences = p
        onPreferencesChange?(p)
    }
}

extension EmojiPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    public func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    public func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: ip) as! EmojiCell
        let it = items[ip.item]
        cell.configure(text: it.text, label: it.accessibilityName, small: tab == .kaomoji)
        return cell
    }

    public func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
        tab == .kaomoji ? CGSize(width: max(80, (cv.bounds.width - 24) / 3), height: 40) : CGSize(width: 44, height: 44)
    }

    public func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        let it = items[ip.item]
        var p = preferences
        if let idx = it.entryIndex, let c = catalog, tab != .recents {
            onInsert?(p.pick(c.entries[idx]))
        } else {
            p.recents.record(it.text)
            onInsert?(it.text)
        }
        commit(p)
    }
}

extension EmojiPanelView: UIContextMenuInteractionDelegate {
    /// Long-press on a skin-tone capable emoji offers the five tones and "use for all".
    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = grid.indexPathForItem(at: interaction.location(in: grid)), let idx = items[ip.item].entryIndex,
              let c = catalog, c.entries[idx].supportsSkinTone else { return nil }
        let entry = c.entries[idx]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = SkinTone.allCases.map { tone in
                UIAction(title: entry.variant(tone)) { _ in
                    guard let self else { return }
                    var p = self.preferences
                    p.skinTones.remember(tone, for: entry)
                    self.commit(p)
                    self.onInsert?(p.pick(entry))
                    self.commit(p)
                    if case .group(let g) = self.tab { self.select(.group(g)) }
                }
            }
            actions.append(UIAction(title: "Use this tone for all") { _ in
                guard let self else { return }
                var p = self.preferences
                if let t = p.skinTones.tone(for: entry) { p.skinTones.defaultTone = t }
                self.commit(p)
            })
            return UIMenu(children: actions)
        }
    }
}

private final class EmojiCell: UICollectionViewCell {
    private let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        isAccessibilityElement = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, label l: String, small: Bool) {
        label.text = text
        label.font = .systemFont(ofSize: small ? 15 : 30)
        accessibilityLabel = l
    }
}
#endif
