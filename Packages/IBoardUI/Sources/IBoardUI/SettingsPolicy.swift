import Foundation
import IBoardCore
import IBoardEngine

/// Pure mapping from app settings (IBoardSettings v3) to keyboard behaviour. No typed text involved.
public enum SettingsPolicy {
    public struct Autocorrect: Equatable, Sendable {
        public var enabled: Bool
        public var aggressiveness: AutocorrectAggressiveness
    }

    /// `off` keeps suggestions but never replaces; the others map onto the policy thresholds
    /// (conservative 0.97, balanced 0.90, assertive 0.80 posterior).
    public static func autocorrect(for level: AutocorrectLevel) -> Autocorrect {
        switch level {
        case .off: Autocorrect(enabled: false, aggressiveness: .conservative)
        case .conservative: Autocorrect(enabled: true, aggressiveness: .conservative)
        case .balanced: Autocorrect(enabled: true, aggressiveness: .balanced)
        case .aggressive: Autocorrect(enabled: true, aggressiveness: .assertive)
        }
    }

    /// Haptics need Full Access (P-23) and the app switch.
    public static func hapticsActive(settings: IBoardSettings, hasFullAccess: Bool) -> Bool {
        settings.haptics && hasFullAccess
    }
}
