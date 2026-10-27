import Foundation
import IBoardLayout

// Key flicks (M5-04): a short vertical flick on a letter key types a secondary character without a layer switch.
// Up = number / symbol, down = the key's first long-press alternate. Pure tables; the host decides WHEN it is a flick
// (`GestureArbiter`) and inserts the result. Nothing here sees typed text.

public enum FlickDirection: Sendable, Equatable { case up, down }

public enum KeyFlick {
    /// Keyboard-local switch for the faint secondary glyphs drawn on the keys (the flicks themselves always work).
    /// The companion app cannot write it yet (IBoardSettings has no field; recorded in the roadmap facts).
    public static let hintsDefaultsKey = "iboard.local.flickHints"

    private static let up: [String: String] = [
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5", "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
        "a": "@", "s": "#", "d": "$", "f": "&", "g": "*", "h": "(", "j": ")", "k": "'", "l": "\"",
        "z": "%", "x": "-", "c": "+", "v": "=", "b": "/", "n": ";", "m": ":",
    ]

    /// The text a flick types, or nil when the key has none (non-letters, letters without an alternate).
    /// Down flicks follow shift (the alternate is uppercased); up flicks are digits / symbols and do not.
    public static func text(for identity: KeyIdentity, direction: FlickDirection, uppercase: Bool) -> String? {
        guard case .letter(let s) = identity else { return nil }
        let base = s.lowercased()
        switch direction {
        case .up: return up[base]
        case .down:
            guard let alt = KeyAlternates.options(for: identity, uppercase: false)?.first else { return nil }
            return uppercase ? alt.uppercased() : alt
        }
    }

    /// The faint glyph a letter key shows for its up flick (nil when hints are for other keys only).
    public static func hint(for identity: KeyIdentity) -> String? {
        text(for: identity, direction: .up, uppercase: false)
    }
}
