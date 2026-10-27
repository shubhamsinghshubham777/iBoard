import SwiftUI
import IBoardCore

/// Companion settings for every shipped feature. Writes the whole versioned blob to the App Group; the keyboard
/// reads it without Full Access (P-23). Defaults mirror iOS (D-07); autocorrect is conservative (D-12).
struct SettingsView: View {
    @State private var settings = SettingsStore().load()

    var body: some View {
        Form {
            Section("Typing") {
                Picker("Autocorrect", selection: $settings.autocorrect) {
                    ForEach(AutocorrectLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(settings.autocorrect.explanation).font(.footnote).foregroundStyle(.secondary)
                Toggle("Double-space period", isOn: $settings.doubleSpacePeriod)
                Toggle("Smart punctuation", isOn: $settings.smartPunctuation)
                Toggle("Swipe typing", isOn: $settings.swipeTyping)
                Toggle("Emoji suggestions", isOn: $settings.emojiSuggestions)
                Picker("Spelling", selection: $settings.spellingVariant) {
                    ForEach(SpellingVariantSetting.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.spellingVariant == .auto {
                    Text("Following your device region: \(settings.effectiveSpellingVariant(localeIdentifier: Locale.current.identifier).title).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Toggle("Incognito by default", isOn: $settings.incognitoByDefault)
                Text("Nothing is learned while incognito is on.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Feel") {
                Toggle("Haptic feedback (needs Full Access)", isOn: $settings.haptics)
                if settings.haptics {
                    Picker("Haptic strength", selection: $settings.hapticIntensity) {
                        ForEach(HapticIntensity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Toggle("Key click sound", isOn: $settings.keyClickSound)
                Picker("Long-press time", selection: $settings.longPressDelay) {
                    ForEach(LongPressDelay.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Text("How long to hold a key before its alternates appear. Choose Long if you trigger them by accident.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Layout") {
                Toggle("Number row", isOn: $settings.numberRow)
                Toggle("Comma and period keys", isOn: $settings.punctuationKeys)
                Toggle("Show hint symbols on keys", isOn: $settings.flickHints)
                Text("The small symbol on a key is what a long press or a flick up types.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                HeightPicker(title: "iPhone, portrait", key: HeightKey.make(displayClass: "phone", orientation: "portrait"), settings: $settings)
                HeightPicker(title: "iPhone, landscape", key: HeightKey.make(displayClass: "phone", orientation: "landscape"), settings: $settings)
                HeightPicker(title: "iPhone Duo outer, portrait", key: HeightKey.make(displayClass: "duoOuter", orientation: "portrait"), settings: $settings)
                HeightPicker(title: "iPhone Duo outer, landscape", key: HeightKey.make(displayClass: "duoOuter", orientation: "landscape"), settings: $settings)
                HeightPicker(title: "iPhone Duo inner, portrait", key: HeightKey.make(displayClass: "duoInner", orientation: "portrait"), settings: $settings)
                HeightPicker(title: "iPhone Duo inner, landscape", key: HeightKey.make(displayClass: "duoInner", orientation: "landscape"), settings: $settings)
            } header: {
                Text("Keyboard size")
            } footer: {
                Text("Takes effect the next time the keyboard appears.")
            }
            Section {
                Toggle("Split in portrait", isOn: $settings.duoSplitPortrait)
                Toggle("Split in landscape", isOn: $settings.duoSplitLandscape)
            } header: {
                Text("iPhone Duo inner display")
            } footer: {
                Text("Only applies when the keyboard is shown on the inner display.")
            }
            Section {
                NavigationLink("Theme studio") { ThemeStudioView() }
            }
            Section {
                Button("Reset to defaults", role: .destructive) { settings = .defaults }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: settings) { _, new in SettingsStore().save(new) }
    }
}

struct HeightPicker: View {
    let title: String
    let key: String
    @Binding var settings: IBoardSettings
    var body: some View {
        Picker(title, selection: Binding(
            get: { HeightPreset.nearest(to: settings.heightScale(forKey: key)) },
            set: { settings.heightScales[key] = $0.scale }
        )) {
            ForEach(HeightPreset.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
    }
}

extension AutocorrectLevel {
    var title: String {
        switch self {
        case .off: "Off (suggestions only)"
        case .conservative: "Conservative"
        case .balanced: "Balanced"
        case .aggressive: "Aggressive"
        }
    }
    var explanation: String {
        switch self {
        case .off: "Never replaces what you type; the strip still offers suggestions."
        case .conservative: "Fixes only clear typos. Backspace right after a correction undoes it."
        case .balanced: "Fixes most likely typos."
        case .aggressive: "Corrects eagerly. Backspace right after a correction undoes it."
        }
    }
}

extension SpellingVariantSetting {
    var title: String {
        switch self {
        case .auto: "Follow device"
        case .us: "US English"
        case .uk: "UK English"
        case .in: "Indian English"
        }
    }
}

extension SpellingVariant {
    var title: String {
        switch self {
        case .us: "US English"
        case .uk: "UK English"
        case .in: "Indian English"
        }
    }
}
