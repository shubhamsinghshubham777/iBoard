import Foundation

/// Failure modes when opening a `.iblex` / `.iblm` file. Mirrors docs/LEXICON_FORMAT.md section 2.
public enum LexiconFormatError: Error, Equatable, Sendable {
    case cannotOpen
    case truncated
    case badMagic
    case unsupportedVersion(UInt32)
    case badEndianMarker
    case sizeMismatch
    case checksumMismatch
    case missingSection(UInt32)
    case sectionOutOfBounds(UInt32)
    case badRecordSize(UInt32)
    /// The LM was built against a different lexicon (word count or lexicon checksum differs).
    case lexiconMismatch
}

/// Read-only bytes backed by `mmap` (zero-copy, pages loaded lazily and evictable) or, for in-memory data, a private
/// heap copy. Immutable after init, so sharing across threads is safe.
final class MappedFile: @unchecked Sendable {
    let base: UnsafeRawPointer
    let count: Int
    private let mapped: Bool

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw LexiconFormatError.cannotOpen }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { throw LexiconFormatError.truncated }
        let size = Int(st.st_size)
        let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
        guard let p, p != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw LexiconFormatError.cannotOpen
        }
        base = UnsafeRawPointer(p)
        count = size
        mapped = true
    }

    init(copying data: Data) throws {
        guard !data.isEmpty else { throw LexiconFormatError.truncated }
        let p = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 16)
        data.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: data.count)
        base = UnsafeRawPointer(p)
        count = data.count
        mapped = false
    }

    deinit {
        if mapped {
            munmap(UnsafeMutableRawPointer(mutating: base), count)
        } else {
            UnsafeMutableRawPointer(mutating: base).deallocate()
        }
    }

    @inline(__always) func u16(_ offset: Int) -> UInt16 {
        UInt16(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always) func u32(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

/// A validated container: header checked, section table parsed.
struct Container: Sendable {
    struct Section: Sendable {
        var offset: Int
        var length: Int
        var count: Int
    }

    let file: MappedFile
    let checksum: UInt32
    private let sections: [UInt32: Section]

    static let headerSize = 32
    static let entrySize = 16

    /// - Parameter verifyChecksum: scans the whole file (touches every page). Skip it on the keyboard launch path
    ///   when the file ships inside the signed app bundle; keep it for downloaded or user-supplied files.
    init(file: MappedFile, magic: String, verifyChecksum: Bool) throws {
        self.file = file
        guard file.count >= Self.headerSize else { throw LexiconFormatError.truncated }
        let m = Array(magic.utf8)
        for i in 0..<4 where file.base.load(fromByteOffset: i, as: UInt8.self) != m[i] {
            throw LexiconFormatError.badMagic
        }
        let version = file.u32(4)
        guard version == 1 else { throw LexiconFormatError.unsupportedVersion(version) }
        guard file.u32(8) == 0x0102_0304 else { throw LexiconFormatError.badEndianMarker }
        let n = Int(file.u32(12))
        guard Int(file.u32(16)) == file.count else { throw LexiconFormatError.sizeMismatch }
        let stored = file.u32(24)
        guard Self.headerSize + n * Self.entrySize <= file.count else { throw LexiconFormatError.truncated }
        if verifyChecksum {
            var h: UInt32 = 0x811C_9DC5
            var i = Self.headerSize
            while i < file.count {
                h = (h ^ UInt32(file.base.load(fromByteOffset: i, as: UInt8.self))) &* 0x0100_0193
                i += 1
            }
            guard h == stored else { throw LexiconFormatError.checksumMismatch }
        }
        checksum = stored
        var table: [UInt32: Section] = [:]
        for i in 0..<n {
            let o = Self.headerSize + i * Self.entrySize
            let id = file.u32(o)
            let s = Section(offset: Int(file.u32(o + 4)), length: Int(file.u32(o + 8)), count: Int(file.u32(o + 12)))
            guard s.offset >= 0, s.length >= 0, s.offset + s.length <= file.count else {
                throw LexiconFormatError.sectionOutOfBounds(id)
            }
            table[id] = s
        }
        sections = table
    }

    func section(_ id: UInt32, recordSize: Int? = nil) throws -> Section {
        guard let s = sections[id] else { throw LexiconFormatError.missingSection(id) }
        if let r = recordSize, s.count * r > s.length { throw LexiconFormatError.badRecordSize(id) }
        return s
    }
}
