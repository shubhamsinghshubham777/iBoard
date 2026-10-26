import Foundation

/// Format constants. Keep in sync with docs/LEXICON_FORMAT.md.
public enum LexFormat {
    public static let version: UInt32 = 1
    public static let endianMarker: UInt32 = 0x0102_0304
    public static let headerSize = 32
    public static let sectionEntrySize = 16
    public static let magicLexicon = "IBLX"
    public static let magicLM = "IBLM"
    /// Quantization: stored = round(-ln(p) * scale), clamped to 0...65535.
    public static let quantScale: Double = 2048
    public static let noWord: UInt32 = 0xFFFF_FFFF
    public static let discount: Double = 0.75

    public enum LexSection: UInt32 { case strings = 1, words = 2, nodes = 3, edges = 4 }
    public enum LMSection: UInt32 { case meta = 1, unigramBackoff = 2, bigrams = 3, trigrams = 4 }
}

func quantize(_ p: Double) -> UInt16 {
    guard p > 0 else { return UInt16.max }
    let v = (-log(p) * LexFormat.quantScale).rounded()
    return UInt16(max(0, min(65535, v)))
}

public func dequantize(_ q: UInt16) -> Double { exp(-Double(q) / LexFormat.quantScale) }

struct ByteWriter {
    var bytes: [UInt8] = []
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    mutating func align4() { while bytes.count % 4 != 0 { bytes.append(0) } }
}

/// FNV-1a 32-bit over a byte sequence.
func fnv1a(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var h: UInt32 = 0x811C_9DC5
    for b in bytes { h = (h ^ UInt32(b)) &* 0x0100_0193 }
    return h
}

struct SectionData { let id: UInt32; let count: UInt32; let bytes: [UInt8] }

/// Assembles header + section table + 4-byte aligned sections. Checksum (FNV-1a) covers bytes from offset 32 to EOF.
func assembleContainer(magic: String, sections: [SectionData]) -> [UInt8] {
    var body = ByteWriter()
    var table: [(UInt32, UInt32, UInt32, UInt32)] = []
    let base = LexFormat.headerSize + LexFormat.sectionEntrySize * sections.count
    for s in sections {
        body.align4()
        table.append((s.id, UInt32(base + body.bytes.count), UInt32(s.bytes.count), s.count))
        body.bytes.append(contentsOf: s.bytes)
    }
    body.align4()
    var tableW = ByteWriter()
    for t in table { tableW.u32(t.0); tableW.u32(t.1); tableW.u32(t.2); tableW.u32(t.3) }
    let rest = tableW.bytes + body.bytes
    var h = ByteWriter()
    h.bytes.append(contentsOf: Array(magic.utf8))
    h.u32(LexFormat.version); h.u32(LexFormat.endianMarker); h.u32(UInt32(sections.count))
    h.u32(UInt32(LexFormat.headerSize + rest.count)); h.u32(0); h.u32(fnv1a(rest[...])); h.u32(0)
    return h.bytes + rest
}

/// Validated, read-only view over a container.
struct Container {
    let data: Data
    let sections: [UInt32: (offset: Int, length: Int, count: Int)]
    let checksum: UInt32

    init(data input: Data, magic: String) throws {
        let data = Data(input)
        guard data.count >= LexFormat.headerSize, Array(data.prefix(4)) == Array(magic.utf8) else { throw LexError.badMagic }
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        guard u32(4) == LexFormat.version else { throw LexError.unsupportedVersion }
        guard u32(8) == LexFormat.endianMarker else { throw LexError.badEndian }
        guard Int(u32(16)) == data.count else { throw LexError.truncated }
        let n = Int(u32(12))
        var secs: [UInt32: (offset: Int, length: Int, count: Int)] = [:]
        for i in 0..<n {
            let o = LexFormat.headerSize + i * LexFormat.sectionEntrySize
            let off = Int(u32(o + 4)), len = Int(u32(o + 8))
            guard off % 4 == 0, off + len <= data.count else { throw LexError.truncated }
            secs[u32(o)] = (off, len, Int(u32(o + 12)))
        }
        let sum = fnv1a(Array(data)[LexFormat.headerSize...])
        guard sum == u32(24) else { throw LexError.badChecksum }
        self.data = data; self.sections = secs; self.checksum = sum
    }

    func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
    func u16(_ o: Int) -> UInt16 { data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) } }
    func section(_ id: UInt32) throws -> (offset: Int, length: Int, count: Int) {
        guard let s = sections[id] else { throw LexError.missingSection(id) }
        return s
    }
}

public enum LexError: Error, Equatable {
    case badMagic, unsupportedVersion, badEndian, truncated, badChecksum
    case missingSection(UInt32)
    case invalidInput(String)
}
