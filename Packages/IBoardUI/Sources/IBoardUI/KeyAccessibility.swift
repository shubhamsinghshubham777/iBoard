import Foundation
#if canImport(UIKit)
import UIKit
#endif
import IBoardLayout

/// M13-01: VoiceOver names for keys. Pure so it is testable on macOS; the key grid builds one accessibility element
/// per key from it (the keys are plain layers, so without this VoiceOver sees nothing).
public enum KeyAccessibility {
    public struct Info: Equatable, Sendable {
        public var label: String
        /// Spoken state ("on", "caps lock") or nil.
        public var value: String?
        /// True for keys that type a character; VoiceOver then uses the keyboard-key trait.
        public var typesCharacter: Bool
    }

    /// Voice Control names ("tap delete", "tap enter"): the first is the visible label; extras are common spoken synonyms.
    /// A letter key keeps just its letter (the shifted form is not spoken separately).
    public static func inputLabels(for identity: KeyIdentity, shift: ShiftState, returnEnabled: Bool = true) -> [String] {
        let base = info(for: identity, shift: shift, returnEnabled: returnEnabled).label
        switch identity {
        case .letter(let s): return [s.lowercased()]
        case .delete: return [base, "backspace"]
        case .returnKey: return base == "return" ? [base, "enter"] : [base, "return", "enter"]
        case .shift: return [base, "caps", "capital"]
        case .space: return [base, "spacebar"]
        case .globe: return [base, "globe", "switch keyboard"]
        case .emoji: return [base, "emoji keyboard"]
        case .layerSwitch(let k):
            switch k {
            case .letters: return [base, "ABC"]
            case .numbers, .numberPad, .decimalPad, .phonePad: return [base, "123"]
            case .symbols: return [base, "symbols"]
            }
        default: return [base]
        }
    }

#if canImport(UIKit)
    /// Accessibility traits for a key: keyboard key, plus `.notEnabled` for a dimmed return key and `.selected` for an
    /// active shift. Pure so the element tests do not need a window.
    public static func traits(for identity: KeyIdentity, shift: ShiftState, returnEnabled: Bool = true) -> UIAccessibilityTraits {
        var t: UIAccessibilityTraits = [.keyboardKey]
        if case .returnKey = identity, !returnEnabled { t.insert(.notEnabled) }
        if case .shift = identity, shift != .off { t.insert(.selected) }
        return t
    }
#endif

    public static func info(for identity: KeyIdentity, shift: ShiftState, returnEnabled: Bool = true) -> Info {
        switch identity {
        case .letter(let s):
            let shown = shift == .off ? s : s.uppercased()
            return Info(label: shown, value: nil, typesCharacter: true)
        case .symbol(let s):
            return Info(label: symbolName(s), value: nil, typesCharacter: true)
        case .domainSuffix(let s):
            return Info(label: s, value: nil, typesCharacter: true)
        case .shift:
            let v: String? = switch shift { case .off: nil; case .once: "on"; case .capsLock: "caps lock" }
            return Info(label: "shift", value: v, typesCharacter: false)
        case .delete:
            return Info(label: "delete", value: nil, typesCharacter: false)
        case .layerSwitch(let k):
            let name: String = switch k {
            case .letters: "letters"
            case .numbers: "numbers"
            case .symbols: "more symbols"
            case .numberPad, .decimalPad, .phonePad: "numbers"
            }
            return Info(label: name, value: nil, typesCharacter: false)
        case .space:
            return Info(label: "space", value: nil, typesCharacter: false)
        case .returnKey(let r):
            let name: String = switch r {
            case .default: "return"
            case .go: "go"
            case .google, .yahoo, .search: "search"
            case .join: "join"
            case .next: "next"
            case .route: "route"
            case .send: "send"
            case .done: "done"
            case .emergencyCall: "emergency call"
            case .continue: "continue"
            }
            return Info(label: name, value: returnEnabled ? nil : "dimmed", typesCharacter: false)
        case .globe:
            return Info(label: "next keyboard", value: nil, typesCharacter: false)
        case .emoji:
            return Info(label: "emoji", value: nil, typesCharacter: false)
        }
    }

    /// Spoken names for punctuation: a bare "." or "," is read as nothing or a pause.
    static func symbolName(_ s: String) -> String {
        switch s {
        case ".": "period"
        case ",": "comma"
        case "!": "exclamation mark"
        case "?": "question mark"
        case "'": "apostrophe"
        case "\"": "quotation mark"
        case "-": "hyphen"
        case "_": "underscore"
        case "/": "slash"
        case "\\": "backslash"
        case ":": "colon"
        case ";": "semicolon"
        case "(": "left parenthesis"
        case ")": "right parenthesis"
        case "@": "at sign"
        case "#": "number sign"
        case "&": "ampersand"
        case "*": "asterisk"
        case "+": "plus"
        case "=": "equals"
        case "%": "percent"
        case "$": "dollar"
        case " ": "space"
        default: s
        }
    }

    /// VoiceOver label for a strip slot: the word, or the role when it is a chip.
    public static func stripLabel(slotIndex: Int, text: String) -> String? {
        text.isEmpty ? nil : text
    }
}
