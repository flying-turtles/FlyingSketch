import Compression
import Foundation

public enum ZipError: Error, Equatable {
    case notAZip
    case unsupportedMethod(UInt16)
    case corrupt(String)
    case tooLarge(String)
    case unsafePath(String)
}

/// Minimal, defensive ZIP reader for untrusted archives (`.fzpz`).
///
/// - Reads entries from the central directory; local headers are used only to locate data.
/// - Methods: 0 (stored), 8 (raw deflate). Anything else -> `.unsupportedMethod`.
/// - Encrypted entries (general-purpose bit 0) -> `.corrupt("encrypted")`.
/// - ZIP64 markers (0xFFFFFFFF sizes/offsets, 0xFFFF counts) -> `.corrupt("zip64")`.
/// - Entry > 20 MB uncompressed -> `.tooLarge(name)`; total declared > 100 MB -> `.tooLarge("archive")`.
/// - Names with a `..` component or a leading `/` -> `.unsafePath(name)`.
/// - All structure is validated in `init`; `data(for:)` bounds-checks and verifies CRC-32.
public struct ZipReader: Sendable {
    public static let maxEntrySize = 20 * 1024 * 1024
    public static let maxTotalSize = 100 * 1024 * 1024

    struct Entry: Sendable {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private let bytes: Data
    private let entries: [Entry]
    private let index: [String: Int]

    public var entryNames: [String] { entries.map(\.name) }

    public init(data: Data) throws {
        let d = Data(data)  // normalise startIndex to 0
        self.bytes = d

        // --- End of central directory ---
        guard d.count >= 22 else { throw ZipError.notAZip }
        let lowest = max(0, d.count - 22 - 0xFFFF)
        var eocd = -1
        var i = d.count - 22
        while i >= lowest {
            if Self.u32(d, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let commentLen = Int(Self.u16(d, eocd + 20))
        guard eocd + 22 + commentLen <= d.count else { throw ZipError.corrupt("eocd comment") }
        let diskNo = Self.u16(d, eocd + 4)
        let cdDisk = Self.u16(d, eocd + 6)
        let countOnDisk = Self.u16(d, eocd + 8)
        let count = Self.u16(d, eocd + 10)
        let cdSize = Self.u32(d, eocd + 12)
        let cdOffset = Self.u32(d, eocd + 16)
        if count == 0xFFFF || countOnDisk == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ZipError.corrupt("zip64")
        }
        guard diskNo == 0, cdDisk == 0, countOnDisk == count else { throw ZipError.corrupt("multi-disk") }
        guard Int(cdOffset) + Int(cdSize) <= eocd else { throw ZipError.corrupt("central directory range") }

        // --- Central directory ---
        var list: [Entry] = []
        var map: [String: Int] = [:]
        var total = 0
        var p = Int(cdOffset)
        let cdEnd = p + Int(cdSize)
        for _ in 0..<Int(count) {
            guard p + 46 <= cdEnd, Self.u32(d, p) == 0x0201_4b50 else { throw ZipError.corrupt("central header") }
            let flags = Self.u16(d, p + 8)
            let method = Self.u16(d, p + 10)
            let crc = Self.u32(d, p + 16)
            let csize = Self.u32(d, p + 20)
            let usize = Self.u32(d, p + 24)
            let nameLen = Int(Self.u16(d, p + 28))
            let extraLen = Int(Self.u16(d, p + 30))
            let cmtLen = Int(Self.u16(d, p + 32))
            let offset = Self.u32(d, p + 42)
            let next = p + 46 + nameLen + extraLen + cmtLen
            guard next <= cdEnd else { throw ZipError.corrupt("central header length") }
            let nameBytes = d.subdata(in: (p + 46)..<(p + 46 + nameLen))
            guard let name = String(data: nameBytes, encoding: .utf8) else { throw ZipError.corrupt("name encoding") }

            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw ZipError.corrupt("zip64") }
            if Self.isUnsafe(name) { throw ZipError.unsafePath(name) }
            if flags & 1 != 0 { throw ZipError.corrupt("encrypted") }
            guard method == 0 || method == 8 else { throw ZipError.unsupportedMethod(method) }
            if Int(usize) > Self.maxEntrySize { throw ZipError.tooLarge(name) }
            total += Int(usize)
            if total > Self.maxTotalSize { throw ZipError.tooLarge("archive") }
            if map[name] != nil { throw ZipError.corrupt("duplicate entry") }

            map[name] = list.count
            list.append(Entry(name: name, method: method, crc: crc, compressedSize: Int(csize),
                              uncompressedSize: Int(usize), localOffset: Int(offset)))
            p = next
        }
        self.entries = list
        self.index = map
    }

    public func data(for name: String) throws -> Data {
        guard let idx = index[name] else { throw ZipError.corrupt("missing entry \(name)") }
        let e = entries[idx]

        let h = e.localOffset
        guard h + 30 <= bytes.count, Self.u32(bytes, h) == 0x0403_4b50 else { throw ZipError.corrupt("local header") }
        let start = h + 30 + Int(Self.u16(bytes, h + 26)) + Int(Self.u16(bytes, h + 28))
        let end = start + e.compressedSize
        guard start <= bytes.count, end <= bytes.count else { throw ZipError.corrupt("data range") }
        let raw = bytes.subdata(in: start..<end)

        let out: Data
        switch e.method {
        case 0:
            guard e.compressedSize == e.uncompressedSize else { throw ZipError.corrupt("stored size mismatch") }
            out = raw
        case 8:
            out = try Self.inflate(raw, expected: e.uncompressedSize)
        default:
            throw ZipError.unsupportedMethod(e.method)
        }
        guard Self.crc32(out) == e.crc else { throw ZipError.corrupt("crc mismatch \(name)") }
        return out
    }

    // MARK: - Helpers

    private static func isUnsafe(_ name: String) -> Bool {
        name.hasPrefix("/") || name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            || name.contains("\\") && name.split(separator: "\\").contains("..")
    }

    private static func inflate(_ raw: Data, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        // One spare byte so an over-long stream is detected instead of silently truncated.
        let cap = expected + 1
        var dst = [UInt8](repeating: 0, count: cap)
        let n = raw.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&dst, cap, base, raw.count, nil, COMPRESSION_ZLIB)
        }
        guard n == expected else { throw ZipError.corrupt("inflate size mismatch") }
        return Data(dst[0..<n])
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
