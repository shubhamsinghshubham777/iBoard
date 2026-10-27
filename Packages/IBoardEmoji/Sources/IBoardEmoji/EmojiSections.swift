import Foundation

/// The continuous emoji list (F8 revamp): one scroll through every emoji, grouped under category headers. People
/// remember how far they scrolled, not which category, so the panel is ONE scrolling list; the category chips only
/// jump to a position. Pure and UIKit-free so the layout rules are testable.
public struct EmojiSections: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        /// Header text; empty for search results (no header).
        public var title: String
        /// `nil` for the recents section, else the catalog group index.
        public var group: Int?
        public var count: Int
    }

    public private(set) var sections: [Section]

    /// Recents first (only when non-empty), then every catalog group that has emoji, in catalog order.
    public init(catalog: EmojiCatalog, recentsCount: Int) {
        var out: [Section] = []
        if recentsCount > 0 { out.append(Section(title: "Recently used", group: nil, count: recentsCount)) }
        var counts = [Int](repeating: 0, count: catalog.groups.count)
        for e in catalog.entries { counts[e.group] += 1 }
        for (g, name) in catalog.groups.enumerated() where counts[g] > 0 {
            out.append(Section(title: name, group: g, count: counts[g]))
        }
        sections = out
    }

    /// A single header-less section (search results).
    public init(flat count: Int) { sections = [Section(title: "", group: nil, count: count)] }

    /// Section index that a chip for `group` (`nil` = recents) jumps to, if it exists.
    public func sectionIndex(forGroup group: Int?) -> Int? {
        sections.firstIndex { $0.group == group }
    }

    /// The section whose header is the last one at or above `offsetY`, given each section's top (ascending).
    /// Used to highlight the chip for what is on screen.
    public static func currentSection(offsetY: Double, sectionTops: [Double]) -> Int {
        var current = 0
        for (i, top) in sectionTops.enumerated() where top <= offsetY + 1 { current = i }
        return current
    }

    /// A restorable scroll offset: clamped to the content, never negative.
    public static func clampedOffset(_ saved: Double, contentHeight: Double, viewportHeight: Double) -> Double {
        min(max(saved, 0), max(0, contentHeight - viewportHeight))
    }
}
