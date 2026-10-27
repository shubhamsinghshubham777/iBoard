import SwiftUI

/// Guided, illustrated OTP setup + self-test (M6-04). On-screen behaviour NOT tested (no simulator run).
struct OTPSetupView: View {
    @State private var trigger: OTPTrigger = .message

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("iBoard can show verification codes in the keyboard. A Shortcuts automation hands each matching message to iBoard, which keeps only the code for 10 minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Codes arrive by", selection: $trigger) {
                    ForEach(OTPTrigger.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                ForEach(OTPSetupGuide.steps(for: trigger)) { step in
                    StepCard(step: step)
                }

                NavigationLink {
                    OTPSelfTestView()
                } label: {
                    Label("Test it", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Verification codes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StepCard: View {
    let step: OTPSetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(step.id)")
                    .font(.headline)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    .accessibilityHidden(true)
                Text(step.title).font(.headline)
            }
            Text(step.detail).font(.subheadline)
            Breadcrumb(items: step.path)
            if let note = step.note {
                Label(note, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityElement(children: .contain)
    }
}

/// "Illustration": the tap path drawn as chips, wrapping with the layout width.
private struct Breadcrumb: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 4) {
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Text(item)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.joined(separator: ", then "))
    }
}

/// Minimal wrapping layout so chips flow to the next line at any width / Dynamic Type size.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

struct OTPSelfTestView: View {
    @State private var model = OTPSelfTestModel()

    var body: some View {
        List {
            Section("1. Send yourself a code") {
                Text("From another phone, or by emailing yourself, send a message with a code that contains the trigger word from your automation. For example:")
                    .font(.subheadline)
                Text(OTPSetupGuide.selfTestSampleMessage)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text("The sender must be the one your automation filters on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("2. Wait for it") {
                status
                switch model.test.state {
                case .idle:
                    Button("Start listening") { model.start() }
                case .waiting:
                    Button("Cancel", role: .cancel) { model.reset() }
                case .received, .timedOut:
                    Button("Run again") { model.start() }
                }
            }
            Section {
                Text("If nothing arrives: check the sender filter, that Confirm Before Run is off, and open the Shortcuts app once if you just restarted your phone. In our device tests codes showed up right away, but the exact delay has not been measured.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Test verification codes")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var status: some View {
        switch model.test.state {
        case .idle:
            Label("Not started", systemImage: "circle.dashed")
        case .waiting:
            HStack(spacing: 10) {
                ProgressView()
                Text("Waiting for a code (up to 2 minutes)…")
            }
        case .received(let code):
            VStack(alignment: .leading, spacing: 4) {
                Label("Code received", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(code.code).font(.title2.monospaced().bold())
                if !code.sender.isEmpty { Text("From \(code.sender)").font(.footnote).foregroundStyle(.secondary) }
                Text("It is now offered in the iBoard suggestion strip.").font(.footnote)
            }
        case .timedOut:
            Label("No code arrived in 2 minutes", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
