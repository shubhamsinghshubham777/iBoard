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
}
