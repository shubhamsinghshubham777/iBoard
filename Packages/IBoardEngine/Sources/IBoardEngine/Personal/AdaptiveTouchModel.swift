import CoreGraphics
import Foundation
import IBoardLayout

/// Which touch model applies: one per orientation x display class (F14).
public struct TouchModelContext: Hashable, Sendable, Codable {
    public var orientation: LayoutOrientation
    public var displayClass: DisplayClass
    public init(orientation: LayoutOrientation, displayClass: DisplayClass) {
        self.orientation = orientation
        self.displayClass = displayClass
    }
}

/// One touch of a committed word: where it landed relative to the key the word says was *intended*, in units of that
/// key's own width / height (the `KeyHit.normalized` frame). Only offsets are kept, never the text.
public struct TouchSample: Sendable, Equatable {
    public var key: KeyIdentity
    public var dx: Double
    public var dy: Double
    public init(key: KeyIdentity, dx: Double, dy: Double) { self.key = key; self.dx = dx; self.dy = dy }

    /// Offset of `point` from the centre of `keyFrame`, normalized by the key size.
    public init(key: KeyIdentity, point: CGPoint, keyFrame: CGRect) {
        self.init(key: key, dx: Double((point.x - keyFrame.midX) / keyFrame.width),
                  dy: Double((point.y - keyFrame.midY) / keyFrame.height))
    }
}

/// A committed word as the learner sees it: one sample per letter, plus how it ended.
public struct CommittedWordTouches: Sendable {
    public var samples: [TouchSample]
    /// Decoder confidence in the committed reading (e.g. the literal posterior, or 1 - autocorrect doubt), 0...1.
    public var confidence: Double
    /// The word was changed by autocorrect, a suggestion pick, or the user's own edit.
    public var wasCorrected: Bool
    /// The user reopened / restored it with backspace.
    public var wasRestored: Bool
    public init(samples: [TouchSample], confidence: Double, wasCorrected: Bool = false, wasRestored: Bool = false) {
        self.samples = samples
        self.confidence = confidence
        self.wasCorrected = wasCorrected
        self.wasRestored = wasRestored
    }
}

/// The clean seam towards the tap decoder. `TapDecoderParameters.keyModels` already accepts per-key overrides, so the
/// decoder needs no change: see `AdaptiveTouchModel.apply(to:context:)`.
public protocol TouchSpatialModelProvider: Sendable {
    func keyModels(for context: TouchModelContext) -> [KeyIdentity: KeySpatialModel]
}

public struct AdaptiveTouchConfig: Sendable, Equatable {
    /// Learning rate floor of the exponential moving average (the rate is `max(1/(n+1), alpha)`).
    public var alpha = 0.02
    /// Decoder confidence needed to learn from a word.
    public var minConfidence = 0.9
    /// Words with fewer letters are ignored.
    public var minLetters = 2
    /// Maximum learned shift of a key centre, in key sizes (F14: +-30 %).
    public var maxShift = 0.3
    /// Samples further than this from the intended key centre (per axis) are mis-taps / wrong decodes and ignored.
    public var outlierRadius = 0.75
    /// Shrinkage: with `n` samples the learned mean counts `n / (n + priorStrength)`.
    public var priorStrength = 12.0
    /// Same for the spread (sigma).
    public var sigmaPriorStrength = 60.0
    /// A key's model is only handed to the decoder after this many samples.
    public var minSamplesForOutput = 3
    /// Output sigma bounds (key sizes).
    public var minSigma = 0.18
    public var maxSigma = 0.42
    /// Prior sigma the learned spread is blended with.
    public var priorSigma = 0.30
    public init() {}
}

/// Exponentially weighted moments of one key's touch offsets (mean and covariance), in normalized key units.
public struct KeyTouchStats: Sendable, Equatable {
    public var count: Int = 0
    public var meanX = 0.0, meanY = 0.0
    public var varXX = 0.0, covXY = 0.0, varYY = 0.0

    mutating func add(dx: Double, dy: Double, alpha: Double) {
        count = min(count + 1, 1_000_000)
        guard count > 1 else { meanX = dx; meanY = dy; return }
        let a = max(1.0 / Double(count), alpha)
        let ex = dx - meanX, ey = dy - meanY
        meanX += a * ex
        meanY += a * ey
        // Standard exponentially weighted (co)variance update.
        varXX = (1 - a) * (varXX + a * ex * ex)
        covXY = (1 - a) * (covXY + a * ex * ey)
        varYY = (1 - a) * (varYY + a * ey * ey)
    }
}

/// F14 adaptive touch model. Value type; the owner (keyboard controller) holds it, feeds committed words and rebuilds the
/// decoder parameters from `keyModels(for:)`. Updates only come from `record(...)`, which accepts a word only when it was
/// decoded with high confidence and neither corrected nor restored. Keeps aggregate statistics per key (counts, mean,
/// covariance); the typed text and the order of touches are never stored.
public struct AdaptiveTouchModel: Sendable, TouchSpatialModelProvider {
    public static let currentVersion = 1

    public var config: AdaptiveTouchConfig
    public private(set) var stats: [TouchModelContext: [String: KeyTouchStats]] = [:]

    public init(config: AdaptiveTouchConfig = AdaptiveTouchConfig()) { self.config = config }

    public enum Rejection: Sendable, Equatable {
        case lowConfidence, corrected, restored, tooShort, noUsableSamples
    }

    /// Learns from one committed word. Returns nil when accepted, otherwise why it was ignored.
    @discardableResult
    public mutating func record(_ word: CommittedWordTouches, in context: TouchModelContext) -> Rejection? {
        if word.wasCorrected { return .corrected }
        if word.wasRestored { return .restored }
        if !(word.confidence >= config.minConfidence) { return .lowConfidence }
        if word.samples.count < config.minLetters { return .tooShort }
        var used = 0
        for s in word.samples {
            guard case .letter(let letter) = s.key, letter.count == 1,
                  s.dx.isFinite, s.dy.isFinite,
                  abs(s.dx) <= config.outlierRadius, abs(s.dy) <= config.outlierRadius else { continue }
            stats[context, default: [:]][letter, default: KeyTouchStats()].add(dx: s.dx, dy: s.dy, alpha: config.alpha)
            used += 1
        }
        return used == 0 ? .noUsableSamples : nil
    }

    public func keyStats(_ letter: String, in context: TouchModelContext) -> KeyTouchStats? { stats[context]?[letter] }

    public func sampleCount(in context: TouchModelContext) -> Int {
        stats[context]?.values.reduce(0) { $0 + $1.count } ?? 0
    }

    /// Per-key spatial models for the decoder: shrunk towards the neutral prior, shift clamped to +-`maxShift`.
    public func keyModels(for context: TouchModelContext) -> [KeyIdentity: KeySpatialModel] {
        guard let keys = stats[context] else { return [:] }
        var out: [KeyIdentity: KeySpatialModel] = [:]
        for (letter, s) in keys where s.count >= config.minSamplesForOutput {
            let lam = Double(s.count) / (Double(s.count) + config.priorStrength)
            let mx = max(-config.maxShift, min(config.maxShift, lam * s.meanX))
            let my = max(-config.maxShift, min(config.maxShift, lam * s.meanY))
            // Spread adapts more slowly than the mean: a mis-estimated sigma hurts neutral typists more than a small bias.
            let lamS = Double(s.count) / (Double(s.count) + config.sigmaPriorStrength)
            let p2 = config.priorSigma * config.priorSigma
            let sx = (lamS * s.varXX + (1 - lamS) * p2).squareRoot()
            let sy = (lamS * s.varYY + (1 - lamS) * p2).squareRoot()
            out[.letter(letter)] = KeySpatialModel(
                meanX: mx, meanY: my,
                sigmaX: max(config.minSigma, min(config.maxSigma, sx)),
                sigmaY: max(config.minSigma, min(config.maxSigma, sy)))
        }
        return out
    }

    /// The one-line hook: `adaptive.apply(to: &parameters, context: ctx)` before `TapDecoder(layout:lexicon:model:parameters:)`.
    public func apply(to parameters: inout TapDecoderParameters, context: TouchModelContext) {
        for (k, m) in keyModels(for: context) { parameters.keyModels[k] = m }
    }

    // MARK: Reset

    public mutating func reset(_ context: TouchModelContext) { stats[context] = nil }
    public mutating func resetAll() { stats = [:] }
}

// MARK: - Versioned persistence

public enum AdaptiveTouchCodecError: Error, Equatable {
    case tooLarge, malformed, unsupportedVersion(Int)
}

/// JSON snapshot (`{"version":1,"models":[...]}`). The decoder validates everything: version, sizes, finite numbers,
/// letter keys, and clamps values to the configured ranges, so a corrupt or hostile file can only produce a harmless model.
public enum AdaptiveTouchCodec {
    public static let maxBytes = 256 * 1024

    private struct File: Codable {
        var version: Int
        var models: [Model]
    }
    private struct Model: Codable {
        var orientation: LayoutOrientation
        var displayClass: DisplayClass
        var keys: [Key]
    }
    private struct Key: Codable {
        var k: String
        var n: Int
        var mx, my, sxx, sxy, syy: Double
    }

    public static func encode(_ model: AdaptiveTouchModel) -> Data {
        let models = model.stats.sorted { ($0.key.orientation.rawValue, $0.key.displayClass.rawValue) < ($1.key.orientation.rawValue, $1.key.displayClass.rawValue) }
            .map { ctx, keys in
                Model(orientation: ctx.orientation, displayClass: ctx.displayClass,
                      keys: keys.sorted { $0.key < $1.key }.map {
                          Key(k: $0.key, n: $0.value.count, mx: $0.value.meanX, my: $0.value.meanY,
                              sxx: $0.value.varXX, sxy: $0.value.covXY, syy: $0.value.varYY)
                      })
            }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(File(version: AdaptiveTouchModel.currentVersion, models: models))) ?? Data()
    }

    public static func decode(_ data: Data, config: AdaptiveTouchConfig = AdaptiveTouchConfig()) throws -> AdaptiveTouchModel {
        guard data.count <= maxBytes else { throw AdaptiveTouchCodecError.tooLarge }
        // Peek at the version first so a newer file reports `unsupportedVersion` instead of `malformed`.
        struct Peek: Decodable { var version: Int }
        guard let peek = try? JSONDecoder().decode(Peek.self, from: data) else { throw AdaptiveTouchCodecError.malformed }
        guard peek.version == AdaptiveTouchModel.currentVersion else {
            throw AdaptiveTouchCodecError.unsupportedVersion(peek.version)
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.models.count <= 16 else {
            throw AdaptiveTouchCodecError.malformed
        }
        var model = AdaptiveTouchModel(config: config)
        for m in file.models {
            guard m.keys.count <= 128 else { throw AdaptiveTouchCodecError.malformed }
            let ctx = TouchModelContext(orientation: m.orientation, displayClass: m.displayClass)
            var keys: [String: KeyTouchStats] = [:]
            for k in m.keys {
                guard k.k.count == 1, k.k.unicodeScalars.count <= 2, k.n > 0,
                      [k.mx, k.my, k.sxx, k.sxy, k.syy].allSatisfy(\.isFinite) else { continue }
                var s = KeyTouchStats()
                s.count = min(k.n, 1_000_000)
                s.meanX = max(-1, min(1, k.mx)); s.meanY = max(-1, min(1, k.my))
                s.varXX = max(0, min(1, k.sxx)); s.varYY = max(0, min(1, k.syy))
                s.covXY = max(-1, min(1, k.sxy))
                keys[k.k] = s
            }
            if !keys.isEmpty { model.restore(ctx, keys) }
        }
        return model
    }
}

extension AdaptiveTouchModel {
    fileprivate mutating func restore(_ ctx: TouchModelContext, _ keys: [String: KeyTouchStats]) { stats[ctx] = keys }
}

/// Tiny file store: atomic write, tolerant read (missing or corrupt file gives an empty model).
public struct AdaptiveTouchFileStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load(config: AdaptiveTouchConfig = AdaptiveTouchConfig()) -> AdaptiveTouchModel {
        guard let data = try? Data(contentsOf: url), let m = try? AdaptiveTouchCodec.decode(data, config: config) else {
            return AdaptiveTouchModel(config: config)
        }
        return m
    }

    public func save(_ model: AdaptiveTouchModel) throws {
        try AdaptiveTouchCodec.encode(model).write(to: url, options: .atomic)
    }

    public func delete() { try? FileManager.default.removeItem(at: url) }
}
