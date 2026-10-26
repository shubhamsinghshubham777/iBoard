import CoreGraphics

// Public value types of the layout engine. Everything here is `Sendable` and free of UIKit so the package builds and
// tests on macOS (`swift test`). See docs/LAYOUT_ENGINE.md for the rules behind the numbers.

/// Edge insets in points. Own type so the package does not need UIKit's `UIEdgeInsets`.
public struct LayoutInsets: Sendable, Equatable, Codable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }

    public static let zero = LayoutInsets()
}

/// Which kind of display the keyboard is on. Chosen by the host from the screen, never from a device model.
public enum DisplayClass: String, Sendable, Codable, CaseIterable {
    case phone
    case duoOuter
    case duoInner
}

public enum LayoutOrientation: String, Sendable, Codable, CaseIterable {
    case portrait
    case landscape
}

/// Mirror of `UIKeyboardType` (kept UIKit-free).
public enum KeyboardKind: String, Sendable, Codable, CaseIterable {
    case `default`, asciiCapable, numbersAndPunctuation, url, numberPad, phonePad, namePhonePad
    case emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}

/// Mirror of `UIReturnKeyType`.
public enum ReturnKeyKind: String, Sendable, Codable, CaseIterable {
    case `default`, go, google, join, next, route, search, send, yahoo, done, emergencyCall, `continue`
}

/// Which key set is shown. Shift / caps lock do not change geometry, so they are not part of the kind.
public enum LayoutKind: String, Sendable, Codable, CaseIterable {
    case letters
    case numbers      // "123"
    case symbols      // "#+="
    case numberPad
    case decimalPad
    case phonePad

    public var isPad: Bool {
        switch self {
        case .numberPad, .decimalPad, .phonePad: true
        case .letters, .numbers, .symbols: false
        }
    }

    /// The layer the system opens first for a keyboard type.
    public static func initial(for kind: KeyboardKind) -> LayoutKind {
        switch kind {
        case .numberPad, .asciiCapableNumberPad: .numberPad
        case .decimalPad: .decimalPad
        case .phonePad: .phonePad
        case .numbersAndPunctuation: .numbers
        default: .letters
        }
    }
}

/// Everything the host knows about the environment, as plain values.
public struct LayoutTraits: Sendable, Equatable, Codable {
    public var displayClass: DisplayClass
    public var orientation: LayoutOrientation
    public var keyboardKind: KeyboardKind
    public var returnKey: ReturnKeyKind
    /// `UIInputViewController.needsInputModeSwitchKey`. The globe key exists only when this is true (P-09).
    public var needsInputModeSwitchKey: Bool

    public init(
        displayClass: DisplayClass = .phone,
        orientation: LayoutOrientation = .portrait,
        keyboardKind: KeyboardKind = .default,
        returnKey: ReturnKeyKind = .default,
        needsInputModeSwitchKey: Bool = false
    ) {
        self.displayClass = displayClass
        self.orientation = orientation
        self.keyboardKind = keyboardKind
        self.returnKey = returnKey
        self.needsInputModeSwitchKey = needsInputModeSwitchKey
    }
}

/// Locale currency keys on the 123 / #+= layers. The system shows the locale currency first (measured: rupee).
public struct CurrencySymbols: Sendable, Equatable, Codable {
    public var primary: String
    /// Exactly three symbols shown on the #+= layer.
    public var others: [String]

    public init(primary: String, others: [String]) {
        precondition(others.count == 3, "CurrencySymbols.others must hold exactly 3 symbols")
        self.primary = primary
        self.others = others
    }

    public static let usd = CurrencySymbols(primary: "$", others: ["€", "£", "¥"])
    public static let inr = CurrencySymbols(primary: "₹", others: ["$", "£", "€"])
}

/// Reserved seam for the iPhone Duo centre gap (D-20, F18). NOT implemented: the engine ignores it today and always
/// produces one continuous key area. A later task will make the row builder place keys into two column segments
/// around `centerX +- width/2`; the type exists now so call sites and settings storage do not change.
public struct CentreGap: Sendable, Equatable, Codable {
    public var centerX: CGFloat
    public var width: CGFloat

    public init(centerX: CGFloat, width: CGFloat) {
        self.centerX = centerX
        self.width = width
    }
}

public struct LayoutSettings: Sendable, Equatable, Codable {
    /// Extra row of 1-0 above the letters (letters layer only).
    public var numberRow: Bool
    /// Advisory multiplier (F11) used by `LayoutEngine.preferredHeight`. The layout itself always fills the
    /// container it is given.
    public var heightScale: CGFloat
    /// Comma and period keys flanking the space bar on the letters layer (off in Native; not shown for email/URL).
    public var punctuationKeys: Bool
    public var currency: CurrencySymbols
    /// Reserved (see `CentreGap`); currently ignored.
    public var centreGap: CentreGap?

    public init(
        numberRow: Bool = false,
        heightScale: CGFloat = 1,
        punctuationKeys: Bool = false,
        currency: CurrencySymbols = .usd,
        centreGap: CentreGap? = nil
    ) {
        self.numberRow = numberRow
        self.heightScale = heightScale
        self.punctuationKeys = punctuationKeys
        self.currency = currency
        self.centreGap = centreGap
    }

    /// Defaults per F1/F18: number row off, except on for Duo inner portrait.
    public static func defaults(for traits: LayoutTraits) -> LayoutSettings {
        LayoutSettings(numberRow: traits.displayClass == .duoInner && traits.orientation == .portrait)
    }
}

/// What a key means. Pure identity: shift state (upper/lower case) is applied by the renderer / input layer.
/// Comma and period are `.symbol(",")` / `.symbol(".")`.
public enum KeyIdentity: Hashable, Sendable, Codable {
    /// A letter, always lowercase here ("q").
    case letter(String)
    /// Digit, punctuation, symbol, currency, "+*#".
    case symbol(String)
    /// A multi-character insertion key (".com").
    case domainSuffix(String)
    case shift
    case delete
    /// The 123 / ABC / #+= key; the payload is the layer it switches to.
    case layerSwitch(LayoutKind)
    case space
    case returnKey(ReturnKeyKind)
    case globe

    /// Stable name used in snapshots and tests.
    public var snapshotName: String {
        switch self {
        case .letter(let s): "letter:\(s)"
        case .symbol(let s): "symbol:\(s)"
        case .domainSuffix(let s): "suffix:\(s)"
        case .shift: "shift"
        case .delete: "delete"
        case .layerSwitch(let k): "layer:\(k.rawValue)"
        case .space: "space"
        case .returnKey(let r): "return:\(r.rawValue)"
        case .globe: "globe"
        }
    }

    /// The text a tap inserts, when it is a plain insertion key.
    public var insertionText: String? {
        switch self {
        case .letter(let s), .symbol(let s), .domainSuffix(let s): s
        case .space: " "
        default: nil
        }
    }
}

public struct KeyboardKey: Sendable, Equatable, Identifiable {
    /// Index in `KeyboardLayout.keys` (stable for one layout).
    public let id: Int
    public let identity: KeyIdentity
    /// Visible cap frame in container coordinates (origin top-left).
    public let frame: CGRect
    /// Touch region: the cap frame grown into the surrounding gaps. Regions of all keys tile the key area.
    public let touchRegion: CGRect
    /// Visual row, 0 = top key row.
    public let row: Int

    /// Offset of `point` from the key centre in units of the key's own size (x, y; about -0.5...0.5 inside the
    /// cap, larger inside the gap). This is the coordinate frame the adaptive touch model (F14) learns in, so
    /// it survives resizing and other layouts.
    public func normalizedOffset(of point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.midX) / frame.width, y: (point.y - frame.midY) / frame.height)
    }
}

/// Result of resolving a touch point against the hit model.
public struct KeyHit: Sendable, Equatable {
    public let keyIndex: Int
    /// Key-centre-normalized offset (see `KeyboardKey.normalizedOffset(of:)`).
    public let normalized: CGPoint
    /// False when the point was outside the key area and was clamped to the nearest edge.
    public let isInsideKeyArea: Bool
}
