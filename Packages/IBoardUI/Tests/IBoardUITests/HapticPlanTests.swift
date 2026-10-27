import Foundation
import Testing
import IBoardCore
@testable import IBoardUI

@Suite struct HapticPackTests {
    @Test func standardMatchesShippedFeel() {
        let i = HapticPlan.impact(for: .letter, pack: .standard, intensity: .medium)
        #expect(i?.weight == .light)
        #expect(abs((i?.intensity ?? 0) - 0.85 * 0.8) < 1e-9)
        #expect(HapticPlan.impact(for: .lock, pack: .standard, intensity: .strong)?.weight == .heavy)
    }
    @Test func softIsLighterThanStandard() {
        for k: HapticKind in [.letter, .space, .delete, .lock, .action] {
            let s = HapticPlan.impact(for: k, pack: .soft, intensity: .medium)!
            let n = HapticPlan.impact(for: k, pack: .standard, intensity: .medium)!
            #expect(s.intensity < n.intensity)
        }
        #expect(HapticPlan.impact(for: .delete, pack: .soft, intensity: .medium)?.weight == .light)
    }
    @Test func crispUsesRigidForTyping() {
        #expect(HapticPlan.impact(for: .letter, pack: .crisp, intensity: .strong)?.weight == .rigid)
        #expect(HapticPlan.impact(for: .space, pack: .crisp, intensity: .strong)?.weight == .rigid)
    }
    @Test func lettersOnlySilencesTheRest() {
        #expect(HapticPlan.impact(for: .letter, pack: .lettersOnly, intensity: .light) != nil)
        #expect(HapticPlan.impact(for: .delete, pack: .lettersOnly, intensity: .light) == nil)
        #expect(HapticPlan.impact(for: .action, pack: .lettersOnly, intensity: .light) == nil)
    }
    @Test func packSurvivesSettingsRoundTripAndOldFilesDefault() throws {
        var s = IBoardSettings.defaults
        s.hapticPack = .crisp
        let back = try JSONDecoder().decode(IBoardSettings.self, from: JSONEncoder().encode(s))
        #expect(back.hapticPack == .crisp)
        let old = try JSONDecoder().decode(IBoardSettings.self, from: Data(#"{"version":3,"haptics":true}"#.utf8))
        #expect(old.hapticPack == .standard)
        let bad = try JSONDecoder().decode(IBoardSettings.self, from: Data(#"{"version":3,"hapticPack":"nope"}"#.utf8))
        #expect(bad.hapticPack == .standard)
    }
}
