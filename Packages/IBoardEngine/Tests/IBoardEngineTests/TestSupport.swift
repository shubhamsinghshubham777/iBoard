import Foundation
import IBoardEngine

/// Test fixtures built with Tools/LexiconBuilder (see Fixtures/README.md for how they were generated).
enum Fixture {
    case small, bench, hinglish

    var name: String {
        switch self {
        case .small: return "small"
        case .bench: return "bench"
        case .hinglish: return "hinglish-small"
        }
    }

    func url(_ file: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: file, withExtension: ext, subdirectory: "Fixtures/\(name)")!
    }

    func lexicon(verify: Bool = true) throws -> Lexicon {
        try Lexicon(url: url("lexicon", "iblex"), verifyChecksum: verify)
    }

    func model(lexicon: Lexicon, verify: Bool = true) throws -> NGramModel {
        try NGramModel(url: url("lm", "iblm"), lexicon: lexicon, verifyChecksum: verify)
    }
}

/// Optional bigger fixture directory (outputs of lexicon-builder), for local benchmarking at realistic size:
/// `IBOARD_BENCH_DIR=/path/with/lexicon.iblex+lm.iblm swift test -c release`.
func externalBenchFixture() -> (Lexicon, NGramModel)? {
    guard let dir = ProcessInfo.processInfo.environment["IBOARD_BENCH_DIR"] else { return nil }
    let base = URL(fileURLWithPath: dir)
    guard let lex = try? Lexicon(url: base.appendingPathComponent("lexicon.iblex"), verifyChecksum: false),
          let lm = try? NGramModel(url: base.appendingPathComponent("lm.iblm"), lexicon: lex, verifyChecksum: false)
    else { return nil }
    return (lex, lm)
}

/// Deterministic RNG (SplitMix64) for reproducible synthetic traces.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal via Box-Muller.
    mutating func gaussian() -> Double {
        let u1 = max(Double(next() >> 11) / Double(1 << 53), 1e-12)
        let u2 = Double(next() >> 11) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
