import Foundation
import Testing
@testable import IBoardUI

@Suite("Coach marks")
struct CoachMarksTests {
    @Test func walksThroughTheTipsThenStops() {
        var c = CoachMarks()
        #expect(c.text == CoachMarks.tips[0] && !c.isDone)
        for _ in 0..<(CoachMarks.tips.count - 1) { c.perform(action: 0) }
        #expect(c.isLast && c.actionTitles == ["Done", "Skip"])
        c.perform(action: 0)
        #expect(c.isDone && c.text == nil)
        c.next()
        #expect(c.step == CoachMarks.tips.count)
    }

    @Test func skipEndsItAtOnceAndIsRemembered() {
        var c = CoachMarks()
        c.perform(action: 1)
        #expect(c.isDone)
        let d = UserDefaults(suiteName: "coach.test.\(UUID().uuidString)")!
        CoachStore.save(c, d)
        #expect(CoachStore.load(d).isDone)
        #expect(!CoachStore.load(UserDefaults(suiteName: "coach.test.\(UUID().uuidString)")!).isDone)
    }
}

@Suite("Haptic plan")
struct HapticPlanTests {
    @Test func kindsFeelDifferent() {
        let weights = [HapticKind.letter, .space, .delete, .lock, .action].map(\.weight)
        #expect(Set(weights.map { "\($0)" }).count == 5)
    }

    @Test func wordDeleteRisesAndCaps() {
        let i = (0..<8).map { HapticKind.deleteWord(run: $0).intensity }
        #expect(i == i.sorted() && i.first == 0.5 && i.last == 1)
    }
}

@Suite("Quick punctuation")
struct QuickPunctuationTests {
    @Test func commaAndPeriodOfferPunctuationRows() {
        #expect(KeyAlternates.options(for: .symbol(","))?.contains("!") == true)
        #expect(KeyAlternates.options(for: .symbol("."))?.contains("?") == true)
        #expect(KeyAlternates.options(for: .symbol("."))?.first == "…")
    }
}
