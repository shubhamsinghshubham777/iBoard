import Testing
import Foundation
@testable import IBoardCore

struct SettingsTests {
    private func store() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    }

    @Test func defaultsWhenEmpty() {
        #expect(store().load() == .defaults)
        #expect(IBoardSettings.defaults.haptics == true)
    }

    @Test func roundTrip() throws {
        let s = store()
        let v = IBoardSettings(haptics: false, keyClickSound: true)
        #expect(s.save(v))
        #expect(s.load() == v)
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(IBoardSettings.self, from: data) == v)
    }

    @Test func migratesUnversionedPayload() throws {
        let m = try JSONDecoder().decode(IBoardSettings.self, from: Data(#"{"haptics":false}"#.utf8))
        #expect(m.version == IBoardSettings.currentVersion)
        #expect(m.haptics == false)
        #expect(m.keyClickSound == IBoardSettings.defaults.keyClickSound)
    }

    @Test func newerOrCorruptFallsBackToDefaults() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let s = SettingsStore(defaults: d)
        d.set(Data(#"{"version":99,"haptics":false}"#.utf8), forKey: SettingsStore.key)
        #expect(s.load() == .defaults)
        d.set(Data("garbage".utf8), forKey: SettingsStore.key)
        #expect(s.load() == .defaults)
    }

    @Test func keyIsPrefixed() {
        #expect(SettingsStore.key.hasPrefix(SettingsStore.keyPrefix))
    }

    @Test func migratesV1ToV2WithDefaults() throws {
        let m = try JSONDecoder().decode(IBoardSettings.self, from: Data(#"{"version":1,"haptics":false,"keyClickSound":true}"#.utf8))
        #expect(m.version == 2)
        #expect(m.haptics == false)
        #expect(m.keyClickSound == true)
        #expect(m.numberRow == false)
        #expect(m.heightScales.isEmpty)
        #expect(m.heightScale(forKey: "phone.portrait") == 1)
    }

    @Test func v2RoundTripAndClamp() throws {
        let key = HeightKey.make(displayClass: "phone", orientation: "landscape")
        let v = IBoardSettings(numberRow: true, heightScales: [key: 2.5, "phone.portrait": 0.1])
        let s = store()
        #expect(s.save(v))
        let back = s.load()
        #expect(back == v)
        #expect(back.numberRow)
        #expect(back.heightScale(forKey: key) == 1.4)
        #expect(back.heightScale(forKey: "phone.portrait") == 0.8)
        #expect(HeightScale.clamp(.nan) == 1)
    }

    @Test func localOverridesRoundTrip() {
        let o = LocalLayoutOverrides(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        #expect(o.heightScale(forKey: "phone.portrait") == nil)
        #expect(o.numberRow == nil)
        o.setHeightScale(1.2, forKey: "phone.portrait")
        o.setHeightScale(9, forKey: "phone.landscape")
        o.setNumberRow(true)
        #expect(o.heightScale(forKey: "phone.portrait") == 1.2)
        #expect(o.heightScale(forKey: "phone.landscape") == 1.4)
        #expect(o.numberRow == true)
    }
}
