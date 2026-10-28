import CoreGraphics
import Foundation

/// Learned tap offset (F14, M3-06): where this person's taps land relative to the centre of the key they meant, as a
/// fraction of the key's width / height. Three numbers per person; no text and no touch order are stored. Key
/// selection shifts the touch point by the negative of it, so a thumb that lands high (or left) still picks the
/// intended key. Capped, and only applied once enough taps have been seen.
public struct TouchBias: Codable, Sendable, Equatable {
    public var count = 0
    public var meanX = 0.0
    public var meanY = 0.0

    /// Taps needed before the bias starts to apply, and before it applies in full.
    public static let warmUp = 40
    public static let fullAfter = 120
    /// Slowest adaptation rate (fraction of a new sample's weight): keeps following a changing grip.
    public static let slowestRate = 1.0 / 400
    /// Largest shift ever applied, as a fraction of key width / height.
    public static let maxX = 0.15
    public static let maxY = 0.22
    /// A sample farther than this from the key centre (key fractions) is a mis-tap or a different key: ignored.
    public static let outlier = 0.5

    public init() {}

    /// `dx`, `dy`: touch point minus key centre, divided by the key's width / height.
    public mutating func add(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite, abs(dx) <= Self.outlier, abs(dy) <= Self.outlier else { return }
        count += 1
        let rate = max(1.0 / Double(count), Self.slowestRate)
        meanX += (dx - meanX) * rate
        meanY += (dy - meanY) * rate
    }

    /// The shift (in key fractions) that takes a touch point to where the person meant to tap.
    public var correction: (x: Double, y: Double) {
        let w = min(1, max(0, Double(count - Self.warmUp) / Double(Self.fullAfter - Self.warmUp)))
        func cap(_ v: Double, _ m: Double) -> Double { min(m, max(-m, v)) }
        return (-cap(meanX * w, Self.maxX), -cap(meanY * w, Self.maxY))
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> TouchBias? { data.flatMap { try? JSONDecoder().decode(TouchBias.self, from: $0) } }
}
