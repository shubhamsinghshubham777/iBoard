import Testing
import IBoardCore
@testable import iBoard

struct iBoardTests {
    @Test func appGroupMatchesEntitlementConvention() {
        #expect(SettingsStore.appGroup == "group.app.iBoard")
        #expect(IBoardSettings.defaults.version == IBoardSettings.currentVersion)
    }
}
