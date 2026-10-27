import UIKit
import IBoardCore
import IBoardEmoji
import IBoardUI

/// Emoji panel + search inside the keyboard (M9-01 panel, M9-02 search, wired up).
///
/// Modes: `panel` (categories grid replaces the keys), `search` (the normal keys type into a query that is shown in
/// the strip together with the top two hits; the query lives in memory only), `results` (the panel shows the hits).
/// Memory (F8, P-21): the panel, the catalog and the search index exist only while open; `close()` and a memory
/// warning drop everything. Preferences (recents, skin tones) are only emoji the user tapped; they are kept in the
/// extension's own defaults, never in the App Group (P-23: works without Full Access).
@MainActor
final class EmojiHost {
    enum Mode: Equatable { case closed, panel, search, results }

    static let prefsKey = "iboard.emoji.prefs"

    private(set) var mode: Mode = .closed
    private let store = EmojiStore()
    private var prefs = EmojiPreferences.decode(UserDefaults.standard.data(forKey: EmojiHost.prefsKey))
    private var panel: EmojiPanelView?
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
        makePanel()
        mode = .panel
        onChange?()
        sampleFootprint(after: 0.5)
    }

    func close() {
        guard mode != .closed else { return }
        dropPanel()
        store.dropCaches()
        hits = []
        buffer.clear()
        mode = .closed
        onChange?()
    }

    func updateFrame(_ frame: CGRect) {
        panelFrame = frame
        panel?.frame = frame
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
        refreshHits()
        onChange?()
    }

    private func showResults() {
        guard mode == .search, !hits.isEmpty else { return }
        mode = .results
        panel?.isHidden = false
        panel?.showSearchResults(hits)
        onChange?()
        sampleFootprint(after: 0.3)
    }

    private func refreshHits() {
        let q = buffer.query
        hits = q.isEmpty ? [] : (store.searchIndex()?.search(q, limit: 60).map(\.entryIndex) ?? [])
    }

    /// A character typed on the keys while searching. Returns false when the event is not a search event.
    func handleKey(insert text: String) -> Bool {
        guard mode == .search else { return false }
        if buffer.append(text) { refreshHits(); onChange?() }
        return true
    }

    func handleDeleteBackward() -> Bool {
        guard mode == .search else { return false }
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

    /// Strip contents: the query and the two best hits while searching; a prompt while the panel is up.
    var stripTexts: [String]? {
        switch mode {
        case .closed: return nil
        case .panel: return ["\u{1F50D} Search emoji", "", ""]
        case .search, .results:
            let head = buffer.isEmpty ? "\u{1F50D} Search" : "\u{1F50D} \(buffer.text)"
            guard mode == .search, let catalog = store.catalog() else { return [head, "", ""] }
            let top = hits.prefix(2).compactMap { i in catalog.entries.indices.contains(i) ? prefs.skinTones.resolve(catalog.entries[i]) : nil }
            return [head, top.count > 0 ? top[0] : "", top.count > 1 ? top[1] : ""]
        }
    }

    /// A tap on strip slot `slot` (0...2).
    func tapStrip(slot: Int) {
        switch mode {
        case .closed: return
        case .panel, .results: beginSearch()
        case .search:
            if slot == 0 { showResults(); return }
            let i = slot - 1
            guard i < hits.count, let catalog = store.catalog(), catalog.entries.indices.contains(hits[i]) else { return }
            var p = prefs
            let text = p.pick(catalog.entries[hits[i]])
            prefs = p
            savePrefs()
            onInsert?(text)
            // Back to the panel with fresh recents.
            buffer.clear(); hits = []
            mode = .panel
            makePanel()
            onChange?()
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
