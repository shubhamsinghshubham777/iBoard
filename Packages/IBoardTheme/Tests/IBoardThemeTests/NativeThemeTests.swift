import Foundation
import Testing
@testable import IBoardTheme

private func repoFile(_ rel: String) -> URL {
    // Packages/IBoardTheme/Tests/IBoardThemeTests/<this file>: the repo root is 5 levels up.
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent(rel)
}

@Test func tokensMatchNativeMetricsJSON() throws {
    let data = try Data(contentsOf: repoFile("docs/reference/native-metrics.json"))
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let colors = try #require(root["colors"] as? [String: Any])
    func hex(_ s: String) -> UInt32 { UInt32(s.dropFirst(), radix: 16)! }
    for (name, tokens) in [("light", NativeThemeTokens.light), ("dark", NativeThemeTokens.dark)] {
        let c = try #require(colors[name] as? [String: Any])
        let fills = try #require(c["tile_fill"] as? [String: String])
        #expect(tokens.keyFill.hex == hex(fills["q"]!), "\(name) key fill")
        #expect(tokens.keyLabel.hex == hex(c["letter_color"] as! String), "\(name) label")
        #expect(tokens.actionKeyFill.hex == hex(c["return_go_fill"] as! String), "\(name) action fill")
        #expect(tokens.actionKeyLabel.hex == hex(c["return_go_glyph_color"] as! String), "\(name) action label")
    }
    let fonts = try #require(root["fonts"] as? [String: Any])
    let lower = try #require(fonts["letter_lowercase"] as? [String: Any])
    #expect(NativeThemeTokens.light.letterFontSize == (lower["size_pt"] as! Double))
}

@Test func hexRoundTrip() {
    #expect(ThemeColor(hex: 0x007AFF).hex == 0x007AFF)
    #expect(NativeThemeTokens.tokens(for: .dark) == .dark)
}
