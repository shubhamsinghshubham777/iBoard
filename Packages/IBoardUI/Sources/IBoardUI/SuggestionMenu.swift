import Foundation
import IBoardEngine

/// M3-04: long-press on a suggestion slot opens a small action row (Forget / Never correct / Cancel).
/// Pure policy; the keyboard shows it in the strip and applies the choice to the personal store. The word is only
/// held in memory while the menu shows; never logged or persisted by this type.
public struct SuggestionMenu: Equatable, Sendable {
    public enum Action: Int, CaseIterable, Sendable {
        case forget, neverCorrect, cancel
        public var title: String {
            switch self {
            case .forget: "Forget"
            case .neverCorrect: "Never correct"
            case .cancel: "Cancel"
            }
        }
    }

    public let word: String
    public let slotIndex: Int

    public static var actionTitles: [String] { Action.allCases.map(\.title) }

    /// Banner shown beside the actions.
    public var banner: String { "\u{201C}\(word)\u{201D}" }

    /// The menu for a slot, or nil when there is nothing sensible to forget (empty slot, one-letter text, text with
    /// spaces such as a phrase chip, or digits only).
    public static func menu(for slot: SuggestionSlot?, at index: Int) -> SuggestionMenu? {
        guard let slot else { return nil }
        let w = slot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 2, !w.contains(where: \.isWhitespace), w.contains(where: \.isLetter) else { return nil }
        return SuggestionMenu(word: w, slotIndex: index)
    }

    /// Time a finger rests on the strip before the menu opens.
    public static let holdDelay: TimeInterval = 0.5
    /// A finger moving more than this (pt) while held cancels the long-press.
    public static let moveTolerance: CGFloat = 10
}
