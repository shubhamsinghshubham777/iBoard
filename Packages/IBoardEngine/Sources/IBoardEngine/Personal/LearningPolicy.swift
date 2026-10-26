import Foundation

/// Why learning is suppressed in a field (F4 / F15). The keyboard maps UIKit traits into `FieldTraits`.
public enum ExclusionReason: Sendable, Equatable {
    case secureEntry
    case contentType
    case keyboardType
}

/// `UITextContentType` as its raw string (the engine package does not import UIKit). Matching is case-insensitive.
public struct FieldContentType: Sendable, Equatable {
    public let raw: String?
    public init(rawValue: String?) { raw = rawValue }
    public static let none = FieldContentType(rawValue: nil)

    /// Raw values (lowercased) of content types whose text must never be learned: credentials, payment, contact
    /// handles, codes and identifiers. Anything starting with "creditcard" is also excluded.
    static let excluded: Set<String> = [
        "url", "emailaddress", "username", "password", "newpassword", "onetimecode", "telephonenumber",
        "postalcode", "cellulareid", "cellularimei", "flightnumber", "shipmenttrackingnumber",
    ]

    public var isExcluded: Bool {
        guard let r = raw?.lowercased(), !r.isEmpty else { return false }
        return Self.excluded.contains(r) || r.hasPrefix("creditcard")
    }
}

/// `UIKeyboardType`.
public enum FieldKeyboardKind: Sendable, Equatable {
    case `default`, asciiCapable, numbersAndPunctuation, url, numberPad, phonePad, namePhonePad, emailAddress
    case decimalPad, twitter, webSearch, asciiCapableNumberPad

    public init(uikitRawValue: Int) {
        switch uikitRawValue {
        case 1: self = .asciiCapable
        case 2: self = .numbersAndPunctuation
        case 3: self = .url
        case 4: self = .numberPad
        case 5: self = .phonePad
        case 6: self = .namePhonePad
        case 7: self = .emailAddress
        case 8: self = .decimalPad
        case 9: self = .twitter
        case 10: self = .webSearch
        case 11: self = .asciiCapableNumberPad
        default: self = .default
        }
    }

    /// URL, email, number / decimal / phone pads. (`namePhonePad` is a phone-oriented pad and is excluded too.)
    public var isExcluded: Bool {
        switch self {
        case .url, .emailAddress, .numberPad, .decimalPad, .phonePad, .namePhonePad, .asciiCapableNumberPad: true
        case .default, .asciiCapable, .numbersAndPunctuation, .twitter, .webSearch: false
        }
    }
}

public struct FieldTraits: Sendable, Equatable {
    public var contentType: FieldContentType
    public var keyboardType: FieldKeyboardKind
    public var isSecureTextEntry: Bool

    public init(contentType: FieldContentType = .none, keyboardType: FieldKeyboardKind = .default,
                isSecureTextEntry: Bool = false) {
        self.contentType = contentType
        self.keyboardType = keyboardType
        self.isSecureTextEntry = isSecureTextEntry
    }

    public static let `default` = FieldTraits()

    /// First matching reason, or nil when the field may be learned from.
    public var exclusion: ExclusionReason? {
        if isSecureTextEntry { return .secureEntry }
        if contentType.isExcluded { return .contentType }
        if keyboardType.isExcluded { return .keyboardType }
        return nil
    }
}

/// Incognito model (F15): the user's toggle plus automatic incognito in excluded fields.
public struct IncognitoState: Sendable, Equatable {
    public enum Indicator: Sendable, Equatable {
        case off
        /// The user switched it on.
        case manual
        /// Automatic, because of the field.
        case automatic(ExclusionReason)
    }

    public private(set) var userToggle: Bool
    public private(set) var fieldExclusion: ExclusionReason?

    public init(userToggle: Bool = false, fieldExclusion: ExclusionReason? = nil) {
        self.userToggle = userToggle
        self.fieldExclusion = fieldExclusion
    }

    public var isActive: Bool { userToggle || fieldExclusion != nil }

    /// What the strip should show. A manual toggle wins over the automatic reason.
    public var indicator: Indicator {
        if userToggle { return .manual }
        if let r = fieldExclusion { return .automatic(r) }
        return .off
    }

    public mutating func setUserToggle(_ on: Bool) { userToggle = on }
    public mutating func toggle() { userToggle.toggle() }
    public mutating func fieldChanged(_ traits: FieldTraits) { fieldExclusion = traits.exclusion }
}

/// Which words may be learned at all.
public enum LearnableWord {
    public enum Rejection: Sendable, Equatable {
        case tooShort, tooLong, containsDigit, looksLikeEmail, looksLikeURL, invalidCharacters, looksLikeCode
    }

    private static func isMark(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: true
            default: false
            }
        }
    }

    public static let minLength = 2
    public static let maxLength = 32

    /// nil when `word` may be learned. Conservative: any digit, '@', '/', ':' or '.' rejects; so do symbols,
    /// camel-case noise ("aBcDe"), hex-like strings, long consonant runs and key mashing.
    public static func rejection(_ word: String) -> Rejection? {
        let chars = Array(word)
        if chars.count < minLength { return .tooShort }
        if chars.count > maxLength { return .tooLong }
        if chars.contains(where: { $0.isNumber }) { return .containsDigit }
        if chars.contains("@") { return .looksLikeEmail }
        if chars.contains(where: { $0 == "/" || $0 == ":" || $0 == "." || $0 == "\\" }) { return .looksLikeURL }
        for (i, c) in chars.enumerated() {
            let isConnector = c == "'" || c == "\u{2019}" || c == "-"
            if isConnector { if i == 0 || i == chars.count - 1 { return .invalidCharacters }; continue }
            if !(c.isLetter || isMark(c)) { return .invalidCharacters }
        }
        if chars.first?.isLetter != true { return .invalidCharacters }
        let lower = word.lowercased()
        if lower.hasPrefix("www") { return .looksLikeURL }
        // Lowercase-to-uppercase transitions: one is "iPhone"/"McDonald", two or more is code-like.
        var transitions = 0
        for (a, b) in zip(chars, chars.dropFirst()) where a.isLowercase && b.isUppercase { transitions += 1 }
        if transitions >= 2 { return .looksLikeCode }
        // Same character 4+ times in a row ("sooooo", "aaaa").
        var run = 1
        for (a, b) in zip(chars, chars.dropFirst()) {
            run = (a == b) ? run + 1 : 1
            if run >= 4 { return .looksLikeCode }
        }
        let letters = lower.filter { $0.isLetter }
        if letters.count >= 8, letters.allSatisfy({ "abcdef".contains($0) }) { return .looksLikeCode }
        // Latin words of 5+ letters without a vowel are noise ("hmmmm", "qwrtp").
        if letters.count >= 5, letters.allSatisfy({ $0.isASCII }), !letters.contains(where: { "aeiouy".contains($0) }) {
            return .looksLikeCode
        }
        return nil
    }
}

public struct LearningConfig: Sendable {
    /// Increments for the 1st, 2nd, ... observation of a word (low weight that grows, D-10). Later: `steadyIncrement`.
    public var weightSchedule: [Float] = [0.3, 0.7]
    public var steadyIncrement: Float = 1.0
    /// Increment when the user restored their original after an autocorrect (a deliberate, strong signal).
    public var restoredOriginalIncrement: Float = 1.0
    public var forgetWindowDays: Double = 30
    public var deliberateRetypesToOverrideForget = 3
    /// Words of the current sentence remembered for n-gram/phrase context.
    public var sentenceWindow = 8

    public init() {}

    func increment(forPriorUses uses: Int) -> Float {
        uses < weightSchedule.count ? weightSchedule[uses] : steadyIncrement
    }
}
