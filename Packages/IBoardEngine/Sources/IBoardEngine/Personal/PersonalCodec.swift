import Foundation

public enum PersonalCodecError: Error, Equatable {
    case badMagic, badVersion, truncated, checksumMismatch, malformed
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func string(_ s: String) {
        let b = Array(s.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(b.count))
        data.append(contentsOf: b)
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var pos = 0
    init(_ d: Data) { bytes = [UInt8](d) }
    var remaining: Int { bytes.count - pos }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, remaining >= n else { throw PersonalCodecError.truncated }
        defer { pos += n }
        return bytes[pos..<pos + n]
    }
    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u16() throws -> UInt16 { try take(2).enumerated().reduce(0) { $0 | UInt16($1.element) << (8 * UInt16($1.offset)) } }
    mutating func u32() throws -> UInt32 { try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
    mutating func u64() throws -> UInt64 { try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    mutating func string() throws -> String {
        let n = Int(try u16())
        guard let s = String(bytes: try take(n), encoding: .utf8) else {
            throw PersonalCodecError.malformed
        }
        return s
    }
    /// A count that cannot exceed what the remaining bytes could hold (`minRecord` bytes each).
    mutating func count(minRecord: Int) throws -> Int {
        let n = Int(try u32())
        guard n <= remaining / max(1, minRecord) else { throw PersonalCodecError.truncated }
        return n
    }
}

/// Snapshot file: `IBPS` | version u32 | payload length u32 | CRC32 of payload u32 | payload.
/// The payload begins with the last journal sequence number included in the snapshot.
enum PersonalSnapshotCodec {
    static let magic: [UInt8] = Array("IBPS".utf8)
    static let version: UInt32 = 1

    static func encode(_ s: PersonalModelState, lastSeq: UInt64) -> Data {
        var w = ByteWriter()
        w.u64(lastSeq)
        w.f64(s.halfLife)
        for table in [s.unigrams, s.bigrams, s.trigrams, s.phrases] {
            w.u32(UInt32(table.count))
            for (k, e) in table {
                w.string(k); w.f32(e.weight); w.f64(e.stamp); w.u16(e.uses)
            }
        }
        w.u32(UInt32(s.surfaces.count))
        for (k, v) in s.surfaces { w.string(k); w.string(v) }
        w.u32(UInt32(s.forgotten.count))
        for (k, f) in s.forgotten { w.string(k); w.f64(f.at); w.u8(f.deliberate) }
        w.u32(UInt32(s.neverCorrect.count))
        for k in s.neverCorrect { w.string(k) }

        var out = ByteWriter()
        out.data.append(contentsOf: magic)
        out.u32(version)
        out.u32(UInt32(w.data.count))
        out.u32(CRC32.checksum(w.data))
        out.data.append(w.data)
        return out.data
    }

    static func decode(_ data: Data) throws -> (state: PersonalModelState, lastSeq: UInt64) {
        var h = ByteReader(data)
        guard try Array(h.take(4)) == magic else { throw PersonalCodecError.badMagic }
        guard try h.u32() == version else { throw PersonalCodecError.badVersion }
        let len = Int(try h.u32())
        let crc = try h.u32()
        let payload = try h.take(len)
        guard CRC32.checksum(payload) == crc else { throw PersonalCodecError.checksumMismatch }

        var r = ByteReader(Data(payload))
        let lastSeq = try r.u64()
        var s = PersonalModelState(halfLife: try r.f64())
        guard s.halfLife.isFinite, s.halfLife > 0 else { throw PersonalCodecError.malformed }
        func table(_ r: inout ByteReader) throws -> [String: PersonalEntry] {
            var d: [String: PersonalEntry] = [:]
            for _ in 0..<(try r.count(minRecord: 16)) {
                let k = try r.string()
                d[k] = PersonalEntry(weight: try r.f32(), stamp: try r.f64(), uses: try r.u16())
            }
            return d
        }
        s.unigrams = try table(&r)
        s.bigrams = try table(&r)
        s.trigrams = try table(&r)
        s.phrases = try table(&r)
        for _ in 0..<(try r.count(minRecord: 4)) { s.surfaces[try r.string()] = try r.string() }
        for _ in 0..<(try r.count(minRecord: 11)) {
            let k = try r.string()
            s.forgotten[k] = ForgetEntry(at: try r.f64(), deliberate: try r.u8())
        }
        for _ in 0..<(try r.count(minRecord: 2)) { s.neverCorrect.insert(try r.string()) }
        return (s, lastSeq)
    }
}

/// Journal: one record per line, `crc32hex(8) SP json LF`. A torn or corrupt line is skipped on replay.
enum PersonalJournalCodec {
    struct Record: Codable {
        var s: UInt64          // sequence
        var o: String          // op
        var k: String?         // key / word
        var n: UInt8?          // kind
        var w: Float?          // increment
        var f: String?         // surface
        var t: Double?         // time
    }

    static func record(_ op: PersonalOp, seq: UInt64) -> Record {
        switch op {
        case let .add(kind, key, inc, surface, at): Record(s: seq, o: "add", k: key, n: kind.rawValue, w: inc, f: surface, t: at)
        case let .forget(word, at): Record(s: seq, o: "forget", k: word, t: at)
        case let .unforget(word): Record(s: seq, o: "unforget", k: word)
        case let .bumpForgotten(word): Record(s: seq, o: "bump", k: word)
        case let .addNeverCorrect(word): Record(s: seq, o: "nc+", k: word)
        case let .removeNeverCorrect(word): Record(s: seq, o: "nc-", k: word)
        case .clear: Record(s: seq, o: "clear")
        }
    }

    static func op(_ r: Record) -> PersonalOp? {
        switch r.o {
        case "add":
            guard let k = r.k, let n = r.n, let kind = PersonalNGramKind(rawValue: n), let w = r.w, let t = r.t,
                  w.isFinite, t.isFinite else { return nil }
            return .add(kind: kind, key: k, increment: w, surface: r.f, at: t)
        case "forget": if let k = r.k, let t = r.t, t.isFinite { return .forget(word: k, at: t) } else { return nil }
        case "unforget": return r.k.map { .unforget(word: $0) }
        case "bump": return r.k.map { .bumpForgotten(word: $0) }
        case "nc+": return r.k.map { .addNeverCorrect(word: $0) }
        case "nc-": return r.k.map { .removeNeverCorrect(word: $0) }
        case "clear": return .clear
        default: return nil
        }
    }

    static func encodeLine(_ op: PersonalOp, seq: UInt64) -> Data {
        let json = (try? JSONEncoder().encode(record(op, seq: seq))) ?? Data()
        var line = Data(String(format: "%08x ", CRC32.checksum(json)).utf8)
        line.append(json)
        line.append(0x0A)
        return line
    }

    struct Replay {
        var records: [(seq: UInt64, op: PersonalOp)] = []
        var corruptLines = 0
        /// True when the data is non-empty and does not end with a newline (torn final append).
        var tornTail = false
    }

    static func replay(_ data: Data) -> Replay {
        var out = Replay()
        guard !data.isEmpty else { return out }
        out.tornTail = data.last != 0x0A
        let decoder = JSONDecoder()
        for lineData in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(lineData)
            guard line.count > 9, line[line.startIndex + 8] == 0x20,
                  let crc = UInt32(String(decoding: line.prefix(8), as: UTF8.self), radix: 16) else {
                out.corruptLines += 1; continue
            }
            let json = line.dropFirst(9)
            guard CRC32.checksum(json) == crc, let rec = try? decoder.decode(Record.self, from: Data(json)),
                  let op = op(rec) else { out.corruptLines += 1; continue }
            out.records.append((rec.s, op))
        }
        return out
    }
}
