import SwiftUI
import UIKit
import IBoardCore

/// Companion app root. Layout adapts via size classes only (D-24); no UIScreen/idiom checks.
struct ContentView: View {
    @AppStorage(OnboardingStorage.completedKey) private var onboardingCompleted = false
    @State private var showOnboarding = false
    var body: some View {
        NavigationStack {
            List {
                Section("Set up") {
                    SetupStepsView()
                    Button("Run the guided setup again") { showOnboarding = true }
                    NavigationLink("Verification codes (Shortcuts)") { OTPSetupView() }
                }
                Section("Try it") { TryKeyboardView() }
                Section {
                    NavigationLink("Settings") { SettingsView() }
                    NavigationLink("Dictionary") { DictionaryManagerView() }
                    NavigationLink("Typing insights") { InsightsView() }
                    NavigationLink("Privacy, licenses and about") { AboutView() }
                }
            }
            .navigationTitle("iBoard")
        }
        .onAppear { if !onboardingCompleted { showOnboarding = true } }
        .fullScreenCover(isPresented: $showOnboarding) { OnboardingView() }
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

#Preview { ContentView() }
