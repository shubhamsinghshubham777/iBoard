import SwiftUI
import UniformTypeIdentifiers
import IBoardCore

/// Shared explanation of what works without Full Access (F17). Plain text, no network.
struct FullAccessNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Without Full Access").font(.headline)
            Text("Typing, suggestions, autocorrect and learning all work, and the keyboard reads the settings you choose here. Without Full Access the keyboard cannot share your dictionary or counters with this app, so they cannot be shown here. Edits you make here are queued and applied by the keyboard the next time it opens.")
            Text("Turn Full Access on in Settings > General > Keyboard > Keyboards > iBoard to share them.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct DictionaryManagerView: View {
    @State private var store = DictionaryStore()
    @State private var query = ""
    @State private var sort: DictionarySort = .weight
    @State private var newWord = ""
    @State private var rejectedWord = false

    private var rows: [DictionaryEntry] { DictionaryBrowse.filter(store.visibleEntries, query: query, sort: sort) }

    var body: some View {
        List {
            switch store.snapshot {
            case .loading:
                Section { ProgressView() }
            case .unavailable:
                Section("Nothing shared yet") {
                    Text("The keyboard has not shared a dictionary with this app. This happens when Full Access is off, or iBoard has not been used with it on yet.")
                    FullAccessNote()
                }
            case let .failed(e):
                Section("Dictionary unreadable") { Text(e.message) }
            case let .ready(summary, modified):
                Section {
                    LabeledContent("Words", value: "\(summary.entries.count)")
                    LabeledContent("Phrases", value: "\(summary.phraseCount)")
                    if let modified { LabeledContent("Shared", value: modified.formatted(date: .abbreviated, time: .shortened)) }
                } footer: { Text("A snapshot written by the keyboard. It can be slightly behind what you typed last.") }
            }

            if store.queuedCount > 0 {
                Section { Label("\(store.queuedCount) change(s) queued for the keyboard", systemImage: "clock") } footer: {
                    Text("Applied the next time the keyboard opens. This app cannot confirm when that happens.")
                }
            }

            Section("Add a word") {
                HStack {
                    TextField("Word", text: $newWord).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if rejectedWord { Text("Use a single word up to 64 characters.").font(.footnote).foregroundStyle(.red) }
            }

            Section {
                Picker("Sort", selection: $sort) {
                    Text("Most used").tag(DictionarySort.weight)
                    Text("A to Z").tag(DictionarySort.alphabetical)
                    Text("Count").tag(DictionarySort.uses)
                }
                ForEach(rows) { entry in row(entry) }
            } header: { Text("Words") } footer: {
                if rows.isEmpty, case .ready = store.snapshot { Text(query.isEmpty ? "No words yet." : "No matches.") }
            }

            NavigationLink("Import and export") { DictionaryTransferView(store: store) }
        }
        .navigationTitle("Dictionary")
        .searchable(text: $query, prompt: "Search words")
        .task { await store.reload() }
        .refreshable { await store.reload() }
    }

    private func add() {
        rejectedWord = !store.send(AppCommand.makeAddWord(newWord))
        if !rejectedWord { newWord = "" }
    }

    @ViewBuilder private func row(_ e: DictionaryEntry) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(e.display)
                if e.pendingAdd { Text("Queued").font(.caption).foregroundStyle(.secondary) }
                else if e.uses > 0 { Text("Used \(e.uses) times").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if e.neverCorrect { Image(systemName: "pin.fill").foregroundStyle(.tint).accessibilityLabel("Pinned, never autocorrected") }
        }
        .swipeActions(edge: .trailing) {
            Button("Forget", role: .destructive) { store.send(AppCommand.makeForget(e.word)) }
        }
        .swipeActions(edge: .leading) {
            Button(e.neverCorrect ? "Unpin" : "Pin") { store.send(AppCommand.makeNeverCorrect(e.word, enabled: !e.neverCorrect)) }
                .tint(.orange)
        }
        .contextMenu {
            Button(e.neverCorrect ? "Allow autocorrect" : "Never autocorrect", systemImage: "pin") {
                store.send(AppCommand.makeNeverCorrect(e.word, enabled: !e.neverCorrect))
            }
            Button("Forget", systemImage: "trash", role: .destructive) { store.send(AppCommand.makeForget(e.word)) }
        }
    }
}
