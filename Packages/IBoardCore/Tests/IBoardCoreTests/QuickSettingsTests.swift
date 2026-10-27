import Foundation
import Testing
@testable import IBoardCore

@Suite struct QuickSettingsTests {
    private func store() -> (QuickSettingsStore, UserDefaults, SettingsStore) {
        let l = UserDefaults(suiteName: "qs.local.\(UUID().uuidString)")!
        let g = UserDefaults(suiteName: "qs.group.\(UUID().uuidString)")!
        let gs = SettingsStore(defaults: g)
        return (QuickSettingsStore(local: l, group: gs), l, gs)
    }

    @Test func withoutFullAccessEditStaysLocalAndOverridesApp() {
        let (q, _, gs) = store()
        gs.save(IBoardSettings(swipeTyping: true))
        let eff = q.apply(.swipeTyping(false), hasFullAccess: false)
        #expect(eff.swipeTyping == false)
        #expect(gs.load().swipeTyping == true) // the app does not see it
        #expect(q.effective().swipeTyping == false)
        #expect(q.overrides().swipeTyping == false)
    }

    @Test func withFullAccessWritesBackAndDropsOverride() {
        let (q, _, gs) = store()
        let eff = q.apply(.autocorrect(.aggressive), hasFullAccess: true)
        #expect(eff.autocorrect == .aggressive)
        #expect(gs.load().autocorrect == .aggressive)
        #expect(q.overrides().isEmpty)
    }

    @Test func overridesOnlyTouchTheirFieldAndRoundTrip() {
        let (q, _, gs) = store()
        gs.save(IBoardSettings(numberRow: false, hapticPack: .soft))
        q.apply(.numberRow(true), hasFullAccess: false)
        q.apply(.landscapeSideKeys(false), hasFullAccess: false)
        let e = q.effective()
        #expect(e.numberRow && !e.landscapeSideKeys && e.hapticPack == .soft)
        #expect(SettingsOverrides().applied(to: e) == e)
    }

    @Test func landscapeSideKeysDecodesDefaultAndRoundTrips() throws {
        let old = Data(#"{"version":4,"haptics":true}"#.utf8)
        #expect(try JSONDecoder().decode(IBoardSettings.self, from: old).landscapeSideKeys == true)
        var s = IBoardSettings.defaults
        s.landscapeSideKeys = false
        let back = try JSONDecoder().decode(IBoardSettings.self, from: JSONEncoder().encode(s))
        #expect(back.landscapeSideKeys == false)
    }
}
