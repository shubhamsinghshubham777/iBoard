import Foundation

/// First-run gesture tips shown in the suggestion strip (owner request, 2026-10-27). One short tip at a time, with
/// Next and Skip; skipping or finishing never shows them again. Pure state: the host stores `step` (a plain integer).
public struct CoachMarks: Equatable, Sendable {
    public static let tips: [String] = [
        "Swipe across letters to type",
        "Drag the space bar to move the cursor",
        "Drag delete left to remove words",
        "Hold a key for accents and symbols",
    ]

    /// Index of the tip being shown; `tips.count` (or more) means finished.
    public private(set) var step: Int

    public init(step: Int = 0) { self.step = max(0, step) }

    public var isDone: Bool { step >= Self.tips.count }
    public var text: String? { isDone ? nil : Self.tips[step] }
    public var isLast: Bool { step == Self.tips.count - 1 }
    /// Button titles for the strip's action row.
    public var actionTitles: [String] { isLast ? ["Done", "Skip"] : ["Next", "Skip"] }

    public mutating func next() { if !isDone { step += 1 } }
    public mutating func skip() { step = Self.tips.count }

    /// Applies the tapped action cell (0 = Next / Done, 1 = Skip).
    public mutating func perform(action index: Int) {
        if index == 0 { next() } else { skip() }
    }
}

public enum CoachStore {
    public static let key = "iBoard.coach.step"
    public static func load(_ defaults: UserDefaults = .standard) -> CoachMarks {
        CoachMarks(step: defaults.object(forKey: key) as? Int ?? 0)
    }
    public static func save(_ marks: CoachMarks, _ defaults: UserDefaults = .standard) { defaults.set(marks.step, forKey: key) }
}

/// Which haptic a key action gets: different weights so letters, space, delete and locks feel distinct. The host maps
/// `weight` to an impact generator style and `intensity` to `impactOccurred(intensity:)`.
public enum HapticKind: Equatable, Sendable {
    case letter, space, delete, deleteWord(run: Int), lock, action

    public enum Weight: Equatable, Sendable { case light, medium, rigid, soft, heavy }

    public var weight: Weight {
        switch self {
        case .letter: .light
        case .space: .soft
        case .delete: .rigid
        case .deleteWord: .rigid
        case .lock: .heavy
        case .action: .medium
        }
    }

    /// 0.35...1: a run of word deletes rises (0.5, 0.6, ... 1) so a long hold feels like it is speeding up.
    public var intensity: Double {
        switch self {
        case .deleteWord(let run): min(1, 0.5 + 0.1 * Double(max(0, run)))
        case .letter: 0.8
        case .space: 0.9
        default: 1
        }
    }
}
