import SwiftUI
import UIKit

/// First-run onboarding (M10-01): enable keyboard, Full Access explained, OTP setup, typing test.
/// On-screen behaviour NOT tested (no simulator run).
enum OnboardingStep: Int, CaseIterable, Sendable {
    case enable, fullAccess, codes, tryIt

    var title: String {
        switch self {
        case .enable: "Turn on iBoard"
        case .fullAccess: "Full Access, explained"
        case .codes: "Verification codes"
        case .tryIt: "Try it"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

enum OnboardingStorage {
    static let completedKey = "onboarding.completed"
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OnboardingStorage.completedKey) private var completed = false
    @State private var step: OnboardingStep = .enable

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                            .font(.footnote).foregroundStyle(.secondary)
                        content
                    }
                    .padding(16)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                Divider()
                HStack {
                    if let previous = step.previous {
                        Button("Back") { step = previous }
                    }
                    Spacer()
                    if let next = step.next {
                        Button("Next") { step = next }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Done") { completed = true; dismiss() }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
            }
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { completed = true; dismiss() }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .enable: EnableKeyboardStep()
        case .fullAccess: FullAccessStep()
        case .codes: CodesStep()
        case .tryIt: TypingTestStep()
        }
    }
}

private struct EnableKeyboardStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Open Settings > General > Keyboard > Keyboards > Add New Keyboard, then choose iBoard.", systemImage: "gearshape")
            Label("Optional: tap iBoard in the list and turn on Allow Full Access (next step explains it).", systemImage: "hand.raised")
            Label("In any text field, hold the globe key and pick iBoard.", systemImage: "globe")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
            Text("iOS gives apps no public way to check whether a keyboard is enabled, so iBoard cannot tick this step for you.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

private struct FullAccessStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iBoard does not need Full Access to type. It never sends what you type anywhere. If you choose to turn it on, it enables only: haptics, clipboard history (opt-in), showing learned words and counters in this app, and iCloud sync (opt-in).")
                .font(.subheadline)
            ForEach(FullAccessMatrix.rows, id: \.feature) { row in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: row.withoutFullAccess ? "checkmark.circle.fill" : "lock.fill")
                        .foregroundStyle(row.withoutFullAccess ? .green : .orange)
                        .accessibilityLabel(row.withoutFullAccess ? "Works without Full Access" : "Needs Full Access")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.feature).font(.subheadline)
                        if let note = row.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            Text("Measured on an iPhone 12 running iOS 27.0. You can change Full Access at any time in Settings.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct CodesStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When a field asks for a verification code, iBoard shows a \"Code from Messages\" chip that switches to the system keyboard, which offers the code from your messages. Nothing to set up. Optionally, a Shortcuts automation can pass codes to iBoard so they appear right in the suggestion strip.")
                .font(.subheadline)
            NavigationLink("Optional: automatic codes in the strip") { OTPSetupView() }
                .buttonStyle(.bordered)
            Text("You can skip this and do it later from the main screen.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct TypingTestStep: View {
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tap the field, switch to iBoard with the globe key and type a few words.")
                .font(.subheadline)
            TextField("Type here", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            Text("The text stays in this field on your device and is discarded when you leave.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
