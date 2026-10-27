import SwiftUI

// Privacy page, open-source licenses and data attributions (M10-05). Static text condensed from docs/PRIVACY.md,
// NOTICE and docs/DATA_SOURCES.md; update these when those files change. No network, no web views.

enum LegalContent {
    struct Item: Identifiable { let id = UUID(); let title: String; let body: String }

    static let privacyPoints: [Item] = [
        Item(title: "What you type stays on your device", body: "iBoard never logs or stores the text you type. It learns words only into a local dictionary that you can search, edit, export and erase."),
        Item(title: "No network from the keyboard", body: "The keyboard does not use the network. Features that would need it are opt-in and off by default."),
        Item(title: "No tracking, no data collection", body: "iBoard declares no tracking, no tracking domains and no collected data types in its privacy manifests."),
        Item(title: "Full Access is optional", body: "Typing, suggestions, autocorrect, learning and your settings work without Full Access. iBoard does not ask for Full Access to type. If you turn it on yourself, it enables exactly four things: haptic feedback, clipboard history (opt-in), sharing your dictionary and counters with this app, and iCloud sync (opt-in). Nothing you type is sent anywhere."),
        Item(title: "Counters hold no text", body: "Typing insights are aggregate numbers such as words typed and autocorrect undo rate. You can reset them at any time."),
        Item(title: "Exports are your responsibility", body: "A dictionary export is a plain text file containing your words. Anyone you give it to can read it."),
    ]

    static let licenseHeader = "iBoard is open source under the Apache License, Version 2.0. Copyright 2026 Shubham Singh."

    static let licenses: [Item] = [
        Item(title: "iPhone Duo skills (development tooling)", body: "From github.com/mirzaaghazadeh/iphone-duo-skills. Copyright (c) 2026 Navid Mirzaaghazadeh. MIT License. Not affiliated with, endorsed by, or sponsored by Apple Inc."),
        Item(title: "Swift Concurrency skill (development tooling)", body: "From github.com/AvdLee/Swift-Concurrency-Agent-Skill. Copyright (c) 2026 Antoine van der Lee. MIT License."),
        Item(title: "Contributor Covenant 2.1", body: "The project code of conduct is adapted from the Contributor Covenant (contributor-covenant.org), licensed under CC BY 4.0."),
    ]

    static let dataStatus = "iBoard bundles the language data below. Each file is a derived word list or n-gram model; it contains counts, never text from your device."

    static let plannedData: [Item] = [
        Item(title: "English word list: SCOWL 2020.12.07", body: "Copyright 2000-2018 Kevin Atkinson (http://wordlist.aspell.net/). Permissive notice; includes material from Princeton WordNet, Ispell/VarCon and others. Full notices ship in Data/english/LICENSE.md in the source repository."),
        Item(title: "English frequencies: Leipzig Corpora Collection", body: "English news 2023 and 2024, Universität Leipzig, Wortschatz. CC BY 4.0. D. Goldhahn, T. Eckart, U. Quasthoff, LREC 2012. The derived English data files are distributed under CC BY 4.0."),
        Item(title: "Hinglish data (CC BY-SA 4.0)", body: "Built from Leipzig Hindi news 2019 and 2020 (CC BY 4.0), AI4Bharat Aksharantar Hindi pairs (CC BY / CC0, including rows from Google Dakshina, CC BY-SA 4.0; Madhani et al. 2022, Roark et al. 2020) and word lists written by the iBoard project (CC0). The derived Hinglish files are licensed CC BY-SA 4.0 (creativecommons.org/licenses/by-sa/4.0/) and were changed from the sources: romanized, counted, pruned and quantized."),
        Item(title: "Emoji data: Unicode and CLDR", body: "Emoji 18.0 (emoji-test.txt) and CLDR 49 annotations in English and Hindi. Copyright Unicode, Inc. Unicode License v3. Romanized-Hindi keywords added by the iBoard project (Apache-2.0)."),
        Item(title: "Project-authored lists", body: "Test and seed word lists written for iBoard, CC0 1.0."),
    ]
}

struct PrivacyView: View {
    var body: some View {
        List {
            ForEach(LegalContent.privacyPoints) { p in
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.title).font(.headline)
                    Text(p.body).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Privacy")
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section { Text(LegalContent.licenseHeader) }
            Section("Third-party material") {
                ForEach(LegalContent.licenses) { l in item(l) }
            }
        }
        .navigationTitle("Open-source licenses")
    }
}

struct AttributionsView: View {
    var body: some View {
        List {
            Section { Text(LegalContent.dataStatus) }
            Section("Bundled data") {
                ForEach(LegalContent.plannedData) { l in item(l) }
            }
        }
        .navigationTitle("Data attributions")
    }
}

private func item(_ i: LegalContent.Item) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(i.title).font(.headline)
        Text(i.body).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                NavigationLink("Privacy") { PrivacyView() }
                NavigationLink("Open-source licenses") { LicensesView() }
                NavigationLink("Data attributions") { AttributionsView() }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
                Text("iBoard is a privacy-first, open-source keyboard. Not affiliated with or endorsed by Apple Inc.").foregroundStyle(.secondary)
                Link("Source code and issues", destination: URL(string: "https://github.com/shubhamsinghshubham777/iBoard")!)
            }
        }
        .navigationTitle("About")
    }
}
