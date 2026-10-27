import Foundation
import IBoardCore

/// M8-03: maps a haptic kind, the chosen pack and the intensity setting to one impact (generator weight + strength).
/// Pure so the feel table is testable; the keyboard only fires the result. Never involves typed text.
public enum HapticPlan {
    public struct Impact: Equatable, Sendable {
        public var weight: HapticKind.Weight
        public var intensity: Double
    }

    public static func baseIntensity(_ i: HapticIntensity) -> Double {
        switch i {
        case .light: 0.6
        case .medium: 0.85
        case .strong: 1
        }
    }

    /// nil = this kind is silent in the pack.
    public static func impact(for kind: HapticKind, pack: HapticPack, intensity: HapticIntensity) -> Impact? {
        var weight = kind.weight
        var strength = kind.intensity
        switch pack {
        case .standard: break
        case .soft:
            weight = softer(weight)
            strength *= 0.85
        case .crisp:
            switch kind {
            case .letter, .space, .delete, .deleteWord: weight = .rigid
            default: break
            }
        case .lettersOnly:
            guard kind == .letter else { return nil }
        }
        return Impact(weight: weight, intensity: min(1, baseIntensity(intensity) * strength))
    }

    static func softer(_ w: HapticKind.Weight) -> HapticKind.Weight {
        switch w {
        case .heavy: .medium
        case .rigid, .medium: .light
        case .light, .soft: .soft
        }
    }
}
