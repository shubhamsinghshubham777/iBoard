import SwiftUI
import IBoardCore

/// Typing insights (F16): aggregate counters only. Top learned words come from the shared dictionary snapshot and
/// are shown here only, never stored in the counters.
struct InsightsView: View {
    @State private var counters: InsightCounters?
    @State private var topWords: [String] = []
    @State private var confirmReset = false
    @State private var resetQueued = false
    private let store = InsightsStore()
    private let dictionary = DictionaryStore()

    var body: some View {
        List {
            if let c = counters, !c.isEmpty {
                Section("Typing") {
                    stat("Words typed", "\(c.wordsTyped)")
                    stat("Average speed", c.averageWPM.map { "\(Int($0.rounded())) wpm" } ?? "Not enough data")
                    stat("Swiped words", c.swipeShare.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "None yet")
                }
                Section("Autocorrect") {
                    stat("Accepted", "\(c.autocorrectAccepted)")
                    stat("Undone by you", "\(c.autocorrectReverted)")
                    stat("Undo rate", c.autocorrectRevertRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "None yet")
                }
                Section("Learning") {
                    stat("Words learned", "\(c.wordsLearned)")
                    if !topWords.isEmpty { Text(topWords.joined(separator: ", ")) }
                }
                Section { Button("Reset insights", role: .destructive) { confirmReset = true } } footer: {
                    Text("Only counts are stored, never what you typed.")
                }
            } else if counters != nil {
                Section { Text("No typing has been counted yet.") }
                resetSection
            } else {
                Section("Nothing shared yet") {
                    Text("The keyboard has not shared counters with this app.")
                    FullAccessNote()
                }
                resetSection
            }
            if resetQueued {
                Section { Label("Reset queued for the keyboard", systemImage: "clock") } footer: {
                    Text("The keyboard clears its own counters the next time it opens.")
                }
            }
        }
        .navigationTitle("Typing insights")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Reset all insights?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                counters = store.reset()
                resetQueued = CommandQueueStore().enqueue(.resetInsights) != nil
                topWords = []
            }
        }
    }

    @ViewBuilder private var resetSection: some View {
        Section { Button("Reset insights", role: .destructive) { confirmReset = true } }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func load() async {
        counters = store.load()
        await dictionary.reload()
        topWords = DictionaryBrowse.filter(dictionary.visibleEntries, query: "", sort: .weight).prefix(10).map(\.display)
    }
}
