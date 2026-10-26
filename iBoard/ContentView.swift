import SwiftUI
import UIKit
import IBoardCore

/// Companion app root. Layout adapts via size classes only (D-24); no UIScreen/idiom checks.
struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Set up") { SetupStepsView() }
                Section("Try it") { TryKeyboardView() }
                Section {
                    NavigationLink("Settings") { SettingsView() }
                    NavigationLink("Import and export dictionary") { DictionaryTransferView(store: DictionaryStore()) }
                }
            }
            .navigationTitle("iBoard")
        }
    }
}

struct SetupStepsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Open Settings", systemImage: "1.circle")
            Label("General > Keyboard > Keyboards > Add New Keyboard", systemImage: "2.circle")
            Label("Choose iBoard", systemImage: "3.circle")
            Label("Full Access is optional (needed only for haptics and opt-in features)", systemImage: "4.circle")
        }
        .font(.subheadline)
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
}

struct TryKeyboardView: View {
    @State private var text = ""
    var body: some View {
        TextField("Tap here, then switch to iBoard (globe key)", text: $text, axis: .vertical)
            .lineLimit(3...6)
    }
}

struct SettingsView: View {
    @State private var settings = SettingsStore().load()
    var body: some View {
        Form {
            Toggle("Haptic feedback (needs Full Access)", isOn: $settings.haptics)
            Toggle("Key click sound", isOn: $settings.keyClickSound)
            Toggle("Number row", isOn: $settings.numberRow)
            Section("Keyboard height (80% to 140%)") {
                HeightSlider(title: "iPhone portrait", key: HeightKey.make(displayClass: "phone", orientation: "portrait"), settings: $settings)
                HeightSlider(title: "iPhone landscape", key: HeightKey.make(displayClass: "phone", orientation: "landscape"), settings: $settings)
            }
        }
        .navigationTitle("Settings")
        .onChange(of: settings) { _, new in SettingsStore().save(new) }
    }
}

struct HeightSlider: View {
    let title: String
    let key: String
    @Binding var settings: IBoardSettings
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int((settings.heightScale(forKey: key) * 100).rounded())) %")
            Slider(
                value: Binding(get: { settings.heightScale(forKey: key) }, set: { settings.heightScales[key] = HeightScale.clamp($0) }),
                in: HeightScale.range
            )
        }
    }
}

#Preview { ContentView() }
