#if DEBUG
import IBoardEngine
import IBoardLayout
import SwiftUI

/// Explicit, user-initiated swipe trace recorder (M4-04). The person is shown a word from a fixed prompt list and swipes
/// it over a drawn copy of the letter layout; only the touch coordinates, timestamps and that prompted word are stored,
/// in the app sandbox (Documents/swipe-traces/traces.jsonl), and leave the device only if the person taps Share.
/// Nothing the person types anywhere else is ever recorded. Hook-up: `NavigationLink("Swipe trace recorder") {
/// SwipeTraceRecorderView() }` inside a `#if DEBUG` block of SettingsView (or any debug menu).
struct SwipeTraceRecorderView: View {
    /// Contraction pairs first (ambiguous plain/contracted shapes), recorded plain then contracted.
    private static let contractionPrompts = [
        "ill", "i'll", "its", "it's", "well", "we'll", "were", "we're", "wed", "we'd", "hell", "he'll", "shell", "she'll",
        "id", "i'd", "cant", "can't", "wont", "won't", "dont", "don't", "isnt", "isn't", "wasnt", "wasn't", "lets", "let's",
        "thats", "that's", "whats", "what's", "youre", "you're", "theyre", "they're",
        "didn't", "doesn't", "shouldn't", "wouldn't", "couldn't", "haven't", "i'm", "i've", "you've", "there's",
    ]
    private static let prompts = contractionPrompts + [
        "the", "and", "that", "have", "with", "this", "from", "they", "would", "there", "their", "what", "about",
        "which", "when", "make", "like", "time", "just", "know", "people", "because", "good", "some", "could",
        "them", "other", "than", "then", "now", "look", "only", "come", "over", "think", "also", "back", "after",
        "work", "first", "well", "even", "want", "give", "most", "hello", "thanks", "please", "tomorrow", "meeting",
        "kya", "nahi", "theek", "bahut", "kaise", "abhi", "mujhe", "aapka", "dhanyavaad", "chalo", "bilkul",
    ]
    private static let containerHeight: CGFloat = 260

    @State private var index = 0
    @State private var points: [SwipePoint] = []
    @State private var start: Date?
    @State private var saved: [SwipeTrace] = []
    @State private var status = ""

    private var word: String { Self.prompts[index % Self.prompts.count] }

    var body: some View {
        VStack(spacing: 16) {
            Text("Swipe this word").font(.subheadline).foregroundStyle(.secondary)
            Text(word).font(.system(size: 40, weight: .semibold, design: .rounded)).accessibilityIdentifier("trace-word")
            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: Self.containerHeight)
                let layout = LayoutEngine.layout(containerSize: size, traits: LayoutTraits(), kind: .letters)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for k in layout.keys {
                            guard case .letter(let s) = k.identity else { continue }
                            let r = k.frame.insetBy(dx: 2, dy: 3)
                            ctx.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(.secondary.opacity(0.18)))
                            ctx.draw(Text(s).font(.callout), at: CGPoint(x: r.midX, y: r.midY))
                        }
                        var path = Path()
                        for (i, p) in points.enumerated() {
                            let c = CGPoint(x: p.x, y: p.y)
                            if i == 0 { path.move(to: c) } else { path.addLine(to: c) }
                        }
                        ctx.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { v in
                                if start == nil { start = Date(); points = [] }
                                let t = Date().timeIntervalSince(start ?? Date())
                                points.append(SwipePoint(x: Double(v.location.x), y: Double(v.location.y), t: t))
                            }
                            .onEnded { _ in finish(size: size) })
                }
                .frame(width: size.width, height: size.height)
            }
            .frame(height: Self.containerHeight)
            HStack {
                Button("Skip") { advance() }
                Spacer()
                Text("\(saved.count) saved").foregroundStyle(.secondary)
                Spacer()
                if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
            .padding(.horizontal)
            Text(status).font(.footnote).foregroundStyle(.secondary)
            Text("Only your finger path, its timing and the word shown above are saved, on this device. Nothing else you type is recorded.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
        }
        .padding(.top)
        .navigationTitle("Swipe trace recorder")
        .onAppear { saved = loadSaved() }
    }

    private var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("swipe-traces/traces.jsonl")
    }

    private func loadSaved() -> [SwipeTrace] {
        guard let url = fileURL, let r = try? SwipeTraceFile.load(from: url, strict: false) else { return [] }
        return r.traces
    }

    private func finish(size: CGSize) {
        defer { start = nil }
        guard points.count >= 8 else { status = "Too short, try again."; points = []; return }
        let trace = SwipeTrace(word: word, containerWidth: Double(size.width), containerHeight: Double(size.height),
                               samples: points, source: "ios-recorder", layout: "qwerty-portrait")
        do {
            try trace.validate()
            let all = saved + [trace]
            guard let url = fileURL else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SwipeTraceFile.encode(all).write(to: url, options: .atomic)
            saved = all
            status = "Saved."
            advance()
        } catch {
            status = "Could not save: \(error)"
        }
    }

    private func advance() {
        index += 1
        points = []
    }
}
#endif
