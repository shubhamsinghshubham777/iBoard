import UIKit
import IBoardCore
import IBoardEmoji
import IBoardUI

/// Emoji panel + search inside the keyboard (M9-01 panel, M9-02 search, wired up).
///
/// Modes: `panel` (categories grid replaces the keys), `search` (the normal keys type into a query that is shown in
/// the strip together with the top two hits; the query lives in memory only), `results` (the panel shows the hits).
/// Memory (F8, P-21, owner request 2026-10-27): the panel stays built and hidden after its first use (or after
/// `prewarm`), so opening and closing it is instant. That costs memory the old drop-on-close design did not (about +6 MB
/// measured on the Debug simulator; re-measure on the device); a memory warning still drops the catalog and the search index. Preferences (recents, skin tones) are only emoji the user tapped; they are kept in the
/// extension's own defaults, never in the App Group (P-23: works without Full Access).
@MainActor
final class EmojiHost {
    enum Mode: Equatable { case closed, panel, search, results }

    static let prefsKey = "iboard.emoji.prefs"
    static let scrollKey = "iboard.emoji.scrollOffset"

    private(set) var mode: Mode = .closed
    private let store = EmojiStore()
    private var prefs = EmojiPreferences.decode(UserDefaults.standard.data(forKey: EmojiHost.prefsKey))
    private var panel: EmojiPanelView?
    /// Search results: a scrolling row under the field (the keyboard grows by `searchRowHeight` while it shows).
    private let resultsRow = EmojiResultsRow()
    static let searchRowHeight: CGFloat = 44
    private var resultItems: [Int?] = [] // entry index per row item (nil = a recent emoji, inserted as is)
    private var buffer = EmojiSearchBuffer()
    private var hits: [Int] = []
    private var parent: UIView?
    private var panelFrame = CGRect.zero
    private var interfaceStyle = UIUserInterfaceStyle.unspecified

    /// Insert an emoji / kaomoji into the host text.
    var onInsert: ((String) -> Void)?
    /// Mode, query or hits changed: the controller refreshes the strip, the key visibility and the layer.
    var onChange: (() -> Void)?

    /// DEBUG footprint, simulator only: megabytes above the steady state right before the panel opened.
    private(set) var lastOpenDeltaMB = 0.0
    private(set) var peakDeltaMB = 0.0
    private var baselineMB = 0.0

    /// Extra strip height while the results row is up.
    var searchRowHeight: CGFloat { mode == .search ? Self.searchRowHeight : 0 }

    /// Extra strip height in every emoji mode: the results row while typing, a little air around the field while the
    /// panel or the results grid is up (the system glass leaves ~13 pt above our view, so the field needs that much
    /// room below it to look vertically centred).
    var stripExtraHeight: CGFloat {
        switch mode {
        case .closed: 0
        case .search: Self.searchRowHeight
        case .panel, .results: 12
        }
    }

    var isOpen: Bool { mode != .closed }
    /// The key grid shows its keys unless the panel / results cover the key area.
    var keysHidden: Bool { mode == .panel || mode == .results }

    // MARK: Open / close

    func open(in view: UIView, frame: CGRect, interfaceStyle: UIUserInterfaceStyle) {
        guard mode == .closed else { return }
        parent = view
        panelFrame = frame
        self.interfaceStyle = interfaceStyle
        baselineMB = Perf.memoryFootprintMB()
        peakDeltaMB = 0
        buffer.clear()
        hits = []
        if let p = panel {
            // Resident panel: just show it again (recents rebuilt, scroll position restored by `open()`).
            p.frame = frame
            p.overrideUserInterfaceStyle = interfaceStyle
            p.isHidden = false
            p.open()
        } else {
            makePanel()
        }
        mode = .panel
        onChange?()
        sampleFootprint(after: 0.5)
    }

    func close() {
        guard mode != .closed else { return }
        panel?.isHidden = true // stays resident
        resultsRow.isHidden = true
        hits = []
        buffer.clear()
        mode = .closed
        onChange?()
    }

    /// Builds the panel hidden ahead of its first use so the first open is as fast as every later one.
    func prewarm(in view: UIView, frame: CGRect, interfaceStyle: UIUserInterfaceStyle) {
        guard mode == .closed, panel == nil else { return }
        parent = view
        panelFrame = frame
        self.interfaceStyle = interfaceStyle
        makePanel()
        panel?.isHidden = true
    }

    func updateFrame(_ frame: CGRect) {
        panelFrame = frame
        panel?.frame = frame
        positionRow()
    }

    private func positionRow() {
        resultsRow.frame = CGRect(x: 0, y: panelFrame.minY - Self.searchRowHeight, width: panelFrame.width, height: Self.searchRowHeight)
    }

    /// Memory warning: everything rebuildable goes; an open panel reloads lazily when it is next shown.
    func didReceiveMemoryWarning() {
        panel?.didReceiveMemoryWarning()
        store.dropCaches()
    }

    private func makePanel() {
        dropPanel()
        guard let parent else { return }
        let p = EmojiPanelView(store: store, preferences: prefs)
        p.frame = panelFrame
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        p.overrideUserInterfaceStyle = interfaceStyle
        p.onInsert = { [weak self] text in self?.onInsert?(text) }
        p.onPreferencesChange = { [weak self] new in self?.prefs = new; self?.savePrefs() }
        p.onClose = { [weak self] in self?.close() }
        // One continuous list: remember how far the user scrolled (a plain number, extension-local).
        p.restoredScrollOffset = UserDefaults.standard.object(forKey: Self.scrollKey) as? Double
        p.onScrollOffsetSettled = { UserDefaults.standard.set($0, forKey: Self.scrollKey) }
        p.isHidden = mode == .search
        parent.addSubview(p)
        panel = p
    }

    private func dropPanel() {
        panel?.releaseCaches()
        panel?.removeFromSuperview()
        panel = nil
    }

    private func savePrefs() { UserDefaults.standard.set(prefs.encoded(), forKey: Self.prefsKey) }

    /// "Clear emoji history" (no UI yet).
    func clearHistory() {
        prefs.recents.clear()
        prefs.skinTones.clear()
        savePrefs()
    }

    // MARK: Search

    func beginSearch() {
        guard mode != .closed else { return }
        mode = .search
        panel?.isHidden = true
        if resultsRow.superview == nil, let parent {
            resultsRow.onSelect = { [weak self] i in self?.pickResult(i) }
            parent.addSubview(resultsRow)
        }
        resultsRow.isHidden = false
        positionRow()
        refreshHits()
        onChange?()
    }

    /// A tap on the results row: insert and stay in search so several emoji can be added.
    private func pickResult(_ i: Int) {
        guard mode == .search, resultItems.indices.contains(i) else { return }
        if let e = resultItems[i], let catalog = store.catalog(), catalog.entries.indices.contains(e) {
            var p = prefs
            let text = p.pick(catalog.entries[e])
            prefs = p
            savePrefs()
            onInsert?(text)
        } else if let text = prefs.recents.items.indices.contains(i) ? prefs.recents.items[i] : nil {
            onInsert?(text)
        }
    }

    /// Hits for the query, or the recent emoji while the field is empty.
    private func updateRow() {
        guard mode == .search else { return }
        var rows: [EmojiResultsRow.Item] = []
        resultItems = []
        if buffer.isEmpty {
            for t in prefs.recents.items { rows.append(.init(text: t, accessibilityName: t)); resultItems.append(nil) }
            resultsRow.show(rows, emptyMessage: "Type to search emoji")
        } else if let catalog = store.catalog() {
            for i in hits where catalog.entries.indices.contains(i) {
                let e = catalog.entries[i]
                rows.append(.init(text: prefs.skinTones.resolve(e), accessibilityName: e.name))
                resultItems.append(i)
            }
            resultsRow.show(rows, emptyMessage: "No emoji found")
        }
    }

    private func showResults() {
        guard mode == .search, !hits.isEmpty else { return }
        mode = .results
        resultsRow.isHidden = true
        panel?.isHidden = false
        panel?.showSearchResults(hits)
        onChange?()
        sampleFootprint(after: 0.3)
    }

    private func refreshHits() {
        let q = buffer.query
        hits = q.isEmpty ? [] : (store.searchIndex()?.search(q, limit: 60).map(\.entryIndex) ?? [])
        updateRow()
    }

    /// A character typed on the keys while searching. Returns false when the event is not a search event.
    func handleKey(insert text: String) -> Bool {
        guard mode == .search else { return false }
        if buffer.append(text) { refreshHits(); onChange?() }
        return true
    }

    var queryText: String { buffer.text }
    var hasQuery: Bool { !buffer.isEmpty }

    /// A swiped word replaces the query.
    func setQuery(_ text: String) {
        guard mode == .search else { return }
        buffer.clear(); buffer.append(text)
        refreshHits(); onChange?()
    }

    func handleDeleteBackward() -> Bool {
        guard mode == .search else { return false }
        if buffer.isEmpty { cancelSearch(); return true } // backspace on an empty field steps back to the panel
        if buffer.deleteBackward() { refreshHits(); onChange?() }
        return true
    }

    func handleDeleteWord() -> Bool {
        guard mode == .search else { return false }
        buffer.clear(); refreshHits(); onChange?()
        return true
    }

    func handleReturn() -> Bool {
        guard mode == .search else { return false }
        showResults()
        return true
    }

    /// The strip's search pill: a full-width placeholder while the panel is up, the query (with the top hits beside it)
    /// while typing, the query alone while the results are shown.
    var stripField: SuggestionStripView.SearchField? {
        switch mode {
        case .closed: return nil
        case .panel: return .init(text: "", placeholder: "Search emoji", wide: true)
        case .search: return .init(text: buffer.text, placeholder: "Search emoji", wide: true, trailingAction: "Cancel", focused: true)
        case .results: return .init(text: buffer.text, placeholder: "Search emoji", wide: true, trailingAction: "Cancel")
        }
    }

    /// Slot texts: none; the results live in their own row.
    var stripTexts: [String]? { mode == .closed ? nil : ["", "", ""] }

    /// Leave the search and show the category panel again.
    func cancelSearch() {
        guard mode == .search || mode == .results else { return }
        buffer.clear(); hits = []
        mode = .panel
        resultsRow.isHidden = true
        panel?.isHidden = false
        panel?.open()
        onChange?()
    }

    /// A tap on strip slot `slot` (0...2). `onClear` = the tap landed on the pill's clear button.
    func tapStrip(slot: Int, onClear: Bool = false, onCancel: Bool = false) {
        if onCancel, mode == .search || mode == .results { close(); return } // straight back to normal typing
        switch mode {
        case .closed: return
        case .panel: beginSearch()
        case .results:
            if onClear { cancelSearch() } else { beginSearch() }
        case .search:
            if onClear {
                cancelSearch() // the emoji icon: back to the categories
            } else if !buffer.isEmpty {
                showResults()
            }
        }
    }

    // MARK: Debug footprint

    private func sampleFootprint(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.lastOpenDeltaMB = Perf.memoryFootprintMB() - self.baselineMB
                self.peakDeltaMB = max(self.peakDeltaMB, self.lastOpenDeltaMB)
            }
        }
    }

    var debugLine: String {
        isOpen
            ? String(format: "emoji: %@ +%.1f MB (peak +%.1f)", "\(mode)", lastOpenDeltaMB, peakDeltaMB)
            : String(format: "emoji: closed (last peak +%.1f MB)", peakDeltaMB)
    }
}
