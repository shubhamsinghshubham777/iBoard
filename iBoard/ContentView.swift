import SwiftUI
import UIKit
import IBoardCore

/// Companion app root. Layout adapts via size classes only (D-24); no UIScreen/idiom checks.
struct ContentView: View {
    @AppStorage(OnboardingStorage.completedKey) private var onboardingCompleted = false
    @State private var showOnboarding = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: Destination? = .home
    @State private var showSettings = false

    enum Destination: String, CaseIterable, Identifiable {
        case home = "Set up", settings = "Settings", theme = "Theme studio", dictionary = "Dictionary"
        case insights = "Typing insights", about = "Privacy, licenses and about"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: "keyboard"
            case .settings: "gearshape"
            case .theme: "paintpalette"
            case .dictionary: "character.book.closed"
            case .insights: "chart.bar"
            case .about: "hand.raised"
            }
        }
    }

    var body: some View {
        Group {
            if sizeClass == .regular { wide } else { compact }
        }
        .onAppear { if !onboardingCompleted { showOnboarding = true } }
        .fullScreenCover(isPresented: $showOnboarding) { OnboardingView() }
        .onOpenURL { url in // iboard://settings, from the keyboard's quick settings panel
            guard url.scheme == "iboard", url.host == "settings" else { return }
            showOnboarding = false
            section = .settings
            showSettings = true
        }
    }

    private var compact: some View {
        NavigationStack {
            List {
                homeSections
                Section {
                    NavigationLink("Settings", isActive: $showSettings) { SettingsView() }
                    NavigationLink("Dictionary") { DictionaryManagerView() }
                    NavigationLink("Typing insights") { InsightsView() }
                    NavigationLink("Privacy, licenses and about") { AboutView() }
                }
            }
            .navigationTitle("iBoard")
        }
    }

    /// Wide windows (iPad, iPhone Duo inner display, Split View, Stage Manager): sidebar + detail (M11-06).
    private var wide: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationTitle("iBoard")
        } detail: {
            NavigationStack {
                switch section ?? .home {
                case .home: List { homeSections }.navigationTitle("Set up")
                case .settings: SettingsView()
                case .theme: ThemeStudioView()
                case .dictionary: DictionaryManagerView()
                case .insights: InsightsView()
                case .about: AboutView()
                }
            }
        }
    }

    @ViewBuilder private var homeSections: some View {
        Section("Set up") {
            SetupStepsView()
            Button("Run the guided setup again") { showOnboarding = true }
            NavigationLink("Verification codes (Shortcuts)") { OTPSetupView() }
        }
        Section("Try it") { TryKeyboardView() }
    }
}

struct SetupStepsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Open Settings", systemImage: "1.circle")
            Label("General > Keyboard > Keyboards > Add New Keyboard", systemImage: "2.circle")
            Label("Choose iBoard", systemImage: "3.circle")
            Label("Full Access is optional: it only adds haptics, clipboard history, sharing your dictionary with this app, and iCloud sync", systemImage: "4.circle")
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
