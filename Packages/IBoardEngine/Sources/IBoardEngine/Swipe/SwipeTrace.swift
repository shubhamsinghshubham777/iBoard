import CoreGraphics
import Foundation

/// One recorded swipe with the word the person meant (M4-04). This is the on-disk format for owner-consented real
/// swipe traces; nothing in the engine writes it by itself and no UI exists yet. A trace holds typed text (`word`,
/// `previousWords`), so it must only ever be created with explicit consent and never from normal typing.
///
/// File format ("iBoard swipe traces", `.jsonl`): UTF-8, one compact JSON object per line (a `SwipeTrace`), blank
/// lines and lines starting with `#` ignored. Points are `[x, y, t]` triples, x / y in container points of a layout
/// `containerWidth` x `containerHeight` large, t in seconds from the first sample.
public struct SwipeTrace: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// The intended word, lowercase ASCII letters (a-z) and straight apostrophes.
    public var word: String
    /// Up to two words typed before it (oldest first), for the language / n-gram context. Optional.
    public var previousWords: [String]
    /// Size of the keyboard container the points are in.
    public var containerWidth: Double
    public var containerHeight: Double
    /// `[x, y, t]` samples, touch-down to lift.
    public var points: [[Double]]
    /// Free-form origin, e.g. "owner-iphone12-2026-11", "synthetic". Not used for scoring.
    public var source: String
    /// Optional layout identifier, e.g. "qwerty-portrait".
    public var layout: String?

    public init(word: String, previousWords: [String] = [], containerWidth: Double, containerHeight: Double,
                samples: [SwipePoint], source: String, layout: String? = nil) {
        self.version = Self.currentVersion
        self.word = word
        self.previousWords = previousWords
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
        let t0 = samples.first?.t ?? 0
        self.points = samples.map { [$0.x, $0.y, $0.t - t0] }
        self.source = source
        self.layout = layout
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case unsupportedVersion(Int)
        case badWord(String)
        case badContainer
        case tooFewPoints(Int)
        case badPoint(index: Int)
        case timeNotMonotonic(index: Int)

        public var description: String {
            switch self {
            case .unsupportedVersion(let v): return "unsupported trace version \(v)"
            case .badWord: return "word must be 2+ lowercase ASCII letters or apostrophes"
            case .badContainer: return "container size must be positive and finite"
            case .tooFewPoints(let n): return "needs at least 2 points, has \(n)"
            case .badPoint(let i): return "point \(i) must be 3 finite numbers [x, y, t]"
            case .timeNotMonotonic(let i): return "time goes backwards at point \(i)"
            }
        }
    }

    /// Throws the first problem found. Does not echo the word beyond the error case payload.
    public func validate() throws {
        guard version == Self.currentVersion else { throw ValidationError.unsupportedVersion(version) }
        func ok(_ w: String) -> Bool {
            w.count >= 2 && w.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || $0.value == 39 }
        }
        guard ok(word), previousWords.count <= 2, previousWords.allSatisfy(ok) else { throw ValidationError.badWord(word) }
        guard containerWidth.isFinite, containerHeight.isFinite, containerWidth > 0, containerHeight > 0 else {
            throw ValidationError.badContainer
        }
        guard points.count >= 2 else { throw ValidationError.tooFewPoints(points.count) }
        var lastT = -Double.infinity
        for (i, p) in points.enumerated() {
            guard p.count == 3, p.allSatisfy(\.isFinite) else { throw ValidationError.badPoint(index: i) }
            guard p[2] >= lastT else { throw ValidationError.timeNotMonotonic(index: i) }
            lastT = p[2]
        }
    }

    /// The samples scaled from the recorded container to `size` (identity when sizes match), ready for
    /// `SwipeDecoder.decode(points:)` of a decoder built for a layout of that container size.
    public func swipePoints(scaledTo size: CGSize? = nil) -> [SwipePoint] {
        let sx = size.map { Double($0.width) / containerWidth } ?? 1
        let sy = size.map { Double($0.height) / containerHeight } ?? 1
        return points.compactMap { $0.count == 3 ? SwipePoint(x: $0[0] * sx, y: $0[1] * sy, t: $0[2]) : nil }
    }
}

/// Reading and writing the `.jsonl` trace format.
public enum SwipeTraceFile {
    public struct LineError: Error, CustomStringConvertible {
        public var line: Int
        public var reason: String
        public var description: String { "line \(line): \(reason)" }
    }

    /// Serialises traces, one per line, preceded by a `#` header line.
    public static func encode(_ traces: [SwipeTrace]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var out = Data("# iBoard swipe traces v\(SwipeTrace.currentVersion): one JSON trace per line\n".utf8)
        for t in traces {
            out.append(try enc.encode(t))
            out.append(0x0A)
        }
        return out
    }

    /// Parses and validates every trace. With `strict` (default) the first bad line throws a `LineError`;
    /// otherwise bad lines are skipped and reported in `skipped`.
    public static func decode(_ data: Data, strict: Bool = true) throws -> (traces: [SwipeTrace], skipped: [LineError]) {
        let text = String(decoding: data, as: UTF8.self)
        let dec = JSONDecoder()
        var traces: [SwipeTrace] = []
        var skipped: [LineError] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            do {
                let t = try dec.decode(SwipeTrace.self, from: Data(line.utf8))
                try t.validate()
                traces.append(t)
            } catch {
                let e = LineError(line: i + 1, reason: "\(error)")
                if strict { throw e }
                skipped.append(e)
            }
        }
        return (traces, skipped)
    }

    public static func load(from url: URL, strict: Bool = true) throws -> (traces: [SwipeTrace], skipped: [LineError]) {
        try decode(Data(contentsOf: url), strict: strict)
    }

    /// All `*.jsonl` files directly inside `directory`, sorted by name, concatenated. Missing directory = no traces.
    public static func loadDirectory(_ directory: URL, strict: Bool = true) throws -> [SwipeTrace] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var all: [SwipeTrace] = []
        for n in names.sorted() where n.hasSuffix(".jsonl") {
            all += try load(from: directory.appendingPathComponent(n), strict: strict).traces
        }
        return all
    }
}
