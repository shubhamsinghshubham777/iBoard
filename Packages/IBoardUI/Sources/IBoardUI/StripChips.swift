import Foundation
import IBoardEngine
import IBoardOTP

// Strip chips (M6-03 code chip, M6-06 personal-info chips): which chips replace which suggestion slots. Pure.
//
// Rules
// - Secure fields get no chips, except a one-time-code field.
// - Code chip, PROMINENT (first slot, emphasised, up to 3 codes) when `textContentType == oneTimeCode` or the keyboard
//   is a number pad. Otherwise the newest fresh code takes the last slot (the alternative slot; a smart phrase chip
//   there is kept).
// - Personal-info chips only for the matching content types (`PersonalInfo.values`), never in untyped fields, only
//   while the field is empty. Up to 3 values fill slots 0...2.
// Nothing here reads or stores typed text.

public struct StripChip: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// An OTP chip: the stored code's id (marked as inserted in keyboard memory after the tap).
        case code(id: String)
        case info
        /// M6-05: "Paste code" offer; the pasteboard is read only when the user taps it (P-25), `insert` is empty.
        case clipboardCode
        /// M9-03: the newest clipboard history item, pasted on tap.
        case clipboardItem
    }
    public var display: String
    public var insert: String
    public var source: Source
    public var emphasized: Bool
}

public struct ChipField: Sendable, Equatable {
    /// `UITextContentType` raw value.
    public var contentType: String?
    public var keyboard: FieldKeyboardKind
    public var isSecure: Bool
    /// True when nothing is before the cursor (the proxy context is empty or whitespace).
    public var isEmpty: Bool
    public init(contentType: String?, keyboard: FieldKeyboardKind, isSecure: Bool, isEmpty: Bool) {
        self.contentType = contentType; self.keyboard = keyboard; self.isSecure = isSecure; self.isEmpty = isEmpty
    }

    public var isOneTimeCode: Bool { contentType?.lowercased() == "onetimecode" }
    public var looksNumeric: Bool {
        switch keyboard {
        case .numberPad, .asciiCapableNumberPad, .decimalPad: true
        default: false
        }
    }
    public var codeIsProminent: Bool { isOneTimeCode || looksNumeric }
}

public enum ChipPlanner {
    /// Three entries (one per strip slot); nil keeps the suggestion in that slot.
    public static let pasteCodeTitle = "Paste code"

    /// `clipboardOffer`: Full Access is on, the user enabled the fallback and no fresh code is stored; a code field then
    /// shows a "Paste code" chip that reads the pasteboard on tap (never before).
    public static func plan(codes: [StoredCode], info: PersonalInfo, field: ChipField,
                            suggestions: [SuggestionSlot?] = [nil, nil, nil], clipboardOffer: Bool = false,
                            clipboardItem: String? = nil) -> [StripChip?] {
        var out: [StripChip?] = [nil, nil, nil]
        if field.isSecure, !field.isOneTimeCode { return out }
        if clipboardOffer, codes.isEmpty, field.codeIsProminent {
            out[0] = StripChip(display: pasteCodeTitle, insert: "", source: .clipboardCode, emphasized: false)
            return out
        }
        if field.codeIsProminent, !codes.isEmpty {
            for (i, c) in codes.prefix(3).enumerated() {
                out[i] = StripChip(display: label(c), insert: c.code, source: .code(id: c.id), emphasized: true)
            }
            return out
        }
        if !field.isSecure, field.isEmpty {
            let values = info.values(forContentType: field.contentType)
            if !values.isEmpty {
                for (i, v) in values.prefix(3).enumerated() { out[i] = StripChip(display: v, insert: v, source: .info, emphasized: false) }
                return out
            }
        }
        if let clip = clipboardItem, field.isEmpty, !field.isSecure, codes.isEmpty {
            out[2] = StripChip(display: "\u{1F4CB} " + ClipboardHistory.preview(clip, maxLength: 14), insert: clip,
                               source: .clipboardItem, emphasized: false)
            return out
        }
        if let c = codes.first, !(suggestions.count > 2 && suggestions[2]?.role == .phrase) {
            out[2] = StripChip(display: label(c), insert: c.code, source: .code(id: c.id), emphasized: false)
        }
        return out
    }

    /// Display text: the code, plus the sender label when it is short enough to stay readable in a third of the strip.
    static func label(_ c: StoredCode) -> String {
        let s = c.sender.trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.count > 10 ? c.code : "\(c.code) · \(s)"
    }
}

/// M6-05: pulls a verification code out of pasteboard text. Pure; the keyboard calls it off the main thread on tap.
public enum ClipboardCode {
    /// Longest pasteboard text examined (a copied article is not a message).
    public static let maxLength = 600
    public static func extract(from text: String?) -> String? {
        guard let text, !text.isEmpty, text.count <= maxLength else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare code (4-8 digits, or short alphanumeric with a digit) copied by itself.
        if (4...8).contains(t.count), t.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter) }), t.contains(where: \.isNumber),
           t.allSatisfy(\.isNumber) || t.allSatisfy({ $0.isUppercase || $0.isNumber }) { return t }
        return OTPParser.extract(from: t)?.code
    }
}
