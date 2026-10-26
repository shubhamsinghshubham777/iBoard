/// Mirrors the three-state UIKit text-input traits (`UITextAutocorrectionType`, `UITextSpellCheckingType`,
/// `UITextSmartQuotesType`, `UITextSmartDashesType`): `.default` follows the system default (on for our purposes).
public enum TraitSwitch: Sendable, Equatable {
    case `default`, no, yes

    public var isEnabled: Bool { self != .no }
}
