#if canImport(UIKit)
import UIKit

/// The emoji panel: category bar, lazily-cell'd grid, recents, skin-tone memory, kaomoji tab.
/// Memory (F8, P-21): the catalog is loaded when the panel enters a window and dropped when it leaves
/// or on `didReceiveMemoryWarning()`; cells are reused (a handful of UILabels), never one view per emoji.
/// NOT TESTED on device/simulator: compiled only. See docs/EMOJI_DATA.md for the integration API.
@MainActor
public final class EmojiPanelView: UIView {
    /// Chips: they JUMP inside the one continuous list (or switch to the kaomoji list).
    public enum Tab: Equatable {
        case recents
        case group(Int)
        case kaomoji
        case search
    }

    private enum Mode { case browse, kaomoji, search }

    private struct Item {
        let text: String
        let entryIndex: Int?
        let accessibilityName: String
        let fromRecents: Bool
    }

    // Integration API
    public var onInsert: ((String) -> Void)?
    public var onPreferencesChange: ((EmojiPreferences) -> Void)?
    public var onClose: (() -> Void)?
    /// The list's vertical offset changed and settled (drag/decelerate ended); the host persists the number.
    public var onScrollOffsetSettled: ((Double) -> Void)?
    /// Offset restored on the next `open()` (the last scroll position the host remembered).
    public var restoredScrollOffset: Double?
    public private(set) var preferences: EmojiPreferences

    private let store: EmojiStore
    private var catalog: EmojiCatalog?
    private var sections: [[Item]] = []
    private var sectionInfo = EmojiSections(flat: 0)
    private var mode: Mode = .browse
    /// The chip that matches what is on screen (browse mode) or the active list.
    public private(set) var tab: Tab = .recents
    private let grid: UICollectionView
    private let bar = UIStackView()
    private var tabButtons: [(Tab, UIButton)] = []

    private static let cellID = "emoji.cell"
    private static let headerID = "emoji.header"
    private static let groupGlyphs = ["😀", "🧑", "🐻", "🍔", "🚗", "⚽", "💡", "🔣", "🏳️"]

    public init(store: EmojiStore = EmojiStore(), preferences: EmojiPreferences = EmojiPreferences()) {
        self.store = store
        self.preferences = preferences
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 2, left: 6, bottom: 6, right: 6)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func configure() {
        grid.backgroundColor = .clear
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: Self.cellID)
        grid.register(EmojiHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                      withReuseIdentifier: Self.headerID)
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
        for (i, g) in Self.groupGlyphs.enumerated() { addTab(.group(i), g, "Jump to category \(i + 1)") }
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

    /// Loads data and shows the continuous list at the remembered scroll position (top when none).
    public func open() {
        catalog = store.catalog()
        mode = .browse
        rebuild()
        grid.reloadData()
        layoutIfNeeded()
        grid.layoutIfNeeded()
        let saved = restoredScrollOffset ?? 0
        let y = EmojiSections.clampedOffset(saved, contentHeight: Double(grid.contentSize.height),
                                            viewportHeight: Double(grid.bounds.height))
        grid.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        updateCurrentChip()
    }

    /// Drop everything that can be rebuilt: catalog, item arrays, visible cells.
    public func releaseCaches() {
        sections = []
        sectionInfo = EmojiSections(flat: 0)
        catalog = nil
        store.dropCaches()
        grid.reloadData()
    }

    /// Call from the keyboard view controller's didReceiveMemoryWarning.
    public func didReceiveMemoryWarning() { releaseCaches() }

    // MARK: Content

    /// Builds the section arrays for the current mode (browse: recents + every group; kaomoji: one flat list).
    private func rebuild() {
        if catalog == nil { catalog = store.catalog() }
        switch mode {
        case .browse:
            guard let c = catalog else { sections = []; sectionInfo = EmojiSections(flat: 0); return }
            let recents = preferences.recents.items.map { s -> Item in
                let idx = c.entries.firstIndex { $0.emoji == s || $0.tones.contains(s) }
                return Item(text: s, entryIndex: idx, accessibilityName: idx.map { c.entries[$0].name } ?? s, fromRecents: true)
            }
            sectionInfo = EmojiSections(catalog: c, recentsCount: recents.count)
            sections = sectionInfo.sections.map { info in
                guard let g = info.group else { return recents }
                return c.indices(inGroup: g).map { i in
                    let e = c.entries[i]
                    return Item(text: preferences.skinTones.resolve(e), entryIndex: i, accessibilityName: e.name, fromRecents: false)
                }
            }
        case .kaomoji:
            let items = Kaomoji.categories.flatMap(\.items).map { Item(text: $0, entryIndex: nil, accessibilityName: $0, fromRecents: false) }
            sections = [items]
            sectionInfo = EmojiSections(flat: items.count)
        case .search:
            break // set by `showSearchResults`
        }
    }

    // MARK: Chips

    /// Chips jump inside the continuous list; the kaomoji chip switches to the kaomoji list.
    public func select(_ t: Tab) {
        if catalog == nil { catalog = store.catalog() }
        switch t {
        case .kaomoji:
            mode = .kaomoji
            tab = .kaomoji
            rebuild()
            grid.reloadData()
            grid.setContentOffset(.zero, animated: false)
            highlight(.kaomoji)
        case .recents, .group:
            if mode != .browse {
                mode = .browse
                rebuild()
                grid.reloadData()
                grid.layoutIfNeeded()
            }
            let group: Int? = { if case .group(let g) = t { return g } else { return nil } }()
            // Recents may be empty (no section): the chip then jumps to the top.
            let section = sectionInfo.sectionIndex(forGroup: group) ?? 0
            scroll(toSection: section, animated: false)
            tab = group.map { .group($0) } ?? .recents
            highlight(tab)
            onScrollOffsetSettled?(Double(grid.contentOffset.y))
        case .search:
            break
        }
    }

    private func scroll(toSection section: Int, animated: Bool) {
        guard section < sections.count else { return }
        grid.layoutIfNeeded()
        let top: CGFloat
        if let a = grid.collectionViewLayout.layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)) {
            top = a.frame.minY
        } else { top = 0 }
        let y = EmojiSections.clampedOffset(Double(top), contentHeight: Double(grid.contentSize.height),
                                            viewportHeight: Double(grid.bounds.height))
        grid.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    private func highlight(_ t: Tab?) {
        for (tt, b) in tabButtons {
            // No `isSelected`: the system button style paints a solid accent block over the glyph.
            b.alpha = tt == t ? 1 : 0.55
            b.backgroundColor = tt == t ? UIColor.label.withAlphaComponent(0.12) : .clear
            b.layer.cornerRadius = 8
        }
    }

    /// Browse mode: the chip of the category at the top of the screen follows the scroll.
    private func updateCurrentChip() {
        guard mode == .browse, !sections.isEmpty else { return }
        let layout = grid.collectionViewLayout
        let tops = sections.indices.map { i -> Double in
            Double(layout.layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader,
                                                                at: IndexPath(item: 0, section: i))?.frame.minY ?? 0)
        }
        let i = EmojiSections.currentSection(offsetY: Double(grid.contentOffset.y), sectionTops: tops)
        let g = sectionInfo.sections[min(i, sectionInfo.sections.count - 1)].group
        let t: Tab = g.map { .group($0) } ?? .recents
        if t != tab { tab = t; highlight(t) }
    }

    /// Shows search results (entry indices into the catalog, ranked) in the grid.
    public func showSearchResults(_ entryIndices: [Int]) {
        guard let c = catalog ?? store.catalog() else { return }
        catalog = c
        mode = .search
        tab = .search
        let items = entryIndices.compactMap { i -> Item? in
            guard c.entries.indices.contains(i) else { return nil }
            let e = c.entries[i]
            return Item(text: preferences.skinTones.resolve(e), entryIndex: i, accessibilityName: e.name, fromRecents: false)
        }
        sections = [items]
        sectionInfo = EmojiSections(flat: items.count)
        highlight(nil)
        grid.reloadData()
        grid.setContentOffset(.zero, animated: false)
    }

    fileprivate func commit(_ p: EmojiPreferences) {
        preferences = p
        onPreferencesChange?(p)
    }

    /// Re-renders with the current tones keeping the scroll position (after a tone choice).
    fileprivate func refreshKeepingPosition() {
        guard mode == .browse else { return }
        let y = grid.contentOffset
        rebuild()
        grid.reloadData()
        grid.layoutIfNeeded()
        grid.setContentOffset(y, animated: false)
    }
}

extension EmojiPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    public func numberOfSections(in cv: UICollectionView) -> Int { sections.count }

    public func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].count }

    public func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: ip) as! EmojiCell
        let it = sections[ip.section][ip.item]
        cell.configure(text: it.text, label: it.accessibilityName, small: mode == .kaomoji)
        return cell
    }

    public func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String, at ip: IndexPath) -> UICollectionReusableView {
        let h = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: Self.headerID, for: ip) as! EmojiHeader
        h.label.text = mode == .browse && ip.section < sectionInfo.sections.count ? sectionInfo.sections[ip.section].title : ""
        return h
    }

    public func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        mode == .browse ? CGSize(width: cv.bounds.width, height: 26) : .zero
    }

    public func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
        mode == .kaomoji ? CGSize(width: max(80, (cv.bounds.width - 24) / 3), height: 40) : CGSize(width: 44, height: 44)
    }

    public func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        let it = sections[ip.section][ip.item]
        var p = preferences
        if let idx = it.entryIndex, let c = catalog, !it.fromRecents {
            onInsert?(p.pick(c.entries[idx]))
        } else {
            p.recents.record(it.text)
            onInsert?(it.text)
        }
        // Recents are rebuilt the next time the panel opens, so the list does not jump under the finger.
        commit(p)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) { updateCurrentChip() }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { onScrollOffsetSettled?(Double(scrollView.contentOffset.y)) }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { onScrollOffsetSettled?(Double(scrollView.contentOffset.y)) }
    }
}

extension EmojiPanelView: UIContextMenuInteractionDelegate {
    /// Long-press on a skin-tone capable emoji offers the five tones and "use for all".
    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = grid.indexPathForItem(at: interaction.location(in: grid)), let idx = sections[ip.section][ip.item].entryIndex,
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
                    self.refreshKeepingPosition()
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

private final class EmojiHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
        isAccessibilityElement = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
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
