import CoreGraphics
import Foundation
import Testing
@testable import IBoardLayout

/// Compares iPhone 12 (390 wide) frames with the measured system keyboard (docs/reference/native-metrics.json).
@Suite("Native metrics (iPhone 12, 390 pt)")
struct NativeMetricsTests {
    static let tolerance: CGFloat = 1.0

    struct NativeFrame { let x, y, w, h: Double }

    static func loadNative() throws -> [String: Any] {
        // .../Packages/IBoardLayout/Tests/IBoardLayoutTests/<file> -> repo root is 4 levels up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("docs/reference/native-metrics.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Map the JSON tile name to a key identity; nil = not a tile we model (e.g. the untiled pad "Delete" region).
    static func identity(forNativeName n: String, layer: String) -> KeyIdentity? {
        switch n {
        case "shift": return .shift
        case "delete": return .delete
        case "space": return .space
        case "return": return .returnKey(.default)
        case "numbers": return .layerSwitch(.numbers)
        case "symbols": return .layerSwitch(.symbols)
        case "letters": return .layerSwitch(.letters)
        case ".com": return .domainSuffix(".com")
        case "ampersand": return .symbol("&")
        case "Delete": return nil
        case "go", "send", "next", "done": return .returnKey(ReturnKeyKind(rawValue: n)!)
        default:
            if n.count == 1, n.first!.isLetter, n.first!.isASCII { return .letter(n.lowercased()) }
            return .symbol(n)
        }
    }

    func check(
        native: [String: Any], layout: KeyboardLayout, label: String, expectAllNativeKeys: Bool = true
    ) throws {
        var matched = 0
        for (name, raw) in native {
            guard let f = raw as? [String: Any], let x = f["x"] as? Double, let y = f["y"] as? Double,
                  let w = f["w"] as? Double, let h = f["h"] as? Double else { continue }
            // Letters layer keys are named in lowercase in "letters-lower"; uppercase layers are skipped by callers.
            guard let id = Self.identity(forNativeName: name, layer: label) else { continue }
            guard let key = layout.firstKey(id) else {
                Issue.record("\(label): no key for native '\(name)'")
                continue
            }
            matched += 1
            let t = Self.tolerance
            #expect(abs(key.frame.minX - x) <= t, "\(label) \(name) x \(key.frame.minX) vs \(x)")
            #expect(abs(key.frame.minY - y) <= t, "\(label) \(name) y \(key.frame.minY) vs \(y)")
            #expect(abs(key.frame.width - w) <= t, "\(label) \(name) w \(key.frame.width) vs \(w)")
            #expect(abs(key.frame.height - h) <= t, "\(label) \(name) h \(key.frame.height) vs \(h)")
        }
        #expect(matched > 0)
        _ = expectAllNativeKeys
    }

    func layout(_ kind: LayoutKind, traits: LayoutTraits = LayoutTraits(), settings: LayoutSettings = LayoutSettings()) -> KeyboardLayout {
        LayoutEngine.layout(containerSize: CGSize(width: 390, height: 260), traits: traits, kind: kind, settings: settings)
    }

    @Test func layers() throws {
        let json = try Self.loadNative()
        let layers = try #require((json["layouts"] as? [String: Any])?["layers"] as? [String: Any])
        func light(_ k: String) throws -> [String: Any] {
            try #require((layers[k] as? [String: Any])?["light"] as? [String: Any])
        }
        try check(native: try light("letters-lower"), layout: layout(.letters), label: "letters-lower")
        try check(native: try light("numbers"), layout: layout(.numbers, settings: LayoutSettings(currency: .inr)), label: "numbers")
        try check(native: try light("symbols"), layout: layout(.symbols, settings: LayoutSettings(currency: .inr)), label: "symbols")
    }

    @Test func traits() throws {
        let json = try Self.loadNative()
        let traits = try #require((json["layouts"] as? [String: Any])?["traits"] as? [String: Any])
        func light(_ k: String) throws -> [String: Any] {
            try #require((traits[k] as? [String: Any])?["light"] as? [String: Any])
        }
        try check(native: try light("email"), layout: layout(.letters, traits: LayoutTraits(keyboardKind: .emailAddress)), label: "email")
        try check(native: try light("url"), layout: layout(.letters, traits: LayoutTraits(keyboardKind: .url)), label: "url")
        try check(native: try light("num"), layout: layout(.numberPad), label: "num")
        try check(native: try light("dec"), layout: layout(.decimalPad), label: "dec")
        try check(native: try light("tel"), layout: layout(.phonePad), label: "tel")
        for k in ["go", "send", "next", "done", "nocap"] {
            try check(native: try light(k), layout: layout(.letters, traits: LayoutTraits(returnKey: ReturnKeyKind(rawValue: k) ?? .default)), label: k)
        }
    }

    @Test func nativeTokens() throws {
        let l = layout(.letters)
        #expect(abs(l.metrics.keyHeight - 43) < 1e-9)
        #expect(abs(l.metrics.rowGap - 11) < 1e-9)
        #expect(abs(l.metrics.cornerRadius - 8.5) < 1e-9)
        #expect(l.stripFrame.height == 44)
        #expect(abs(l.metrics.keyWidth - 32.33) <= 0.2)
    }
}
