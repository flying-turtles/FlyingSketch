import Foundation
import Testing
@testable import PartsKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

private func source(_ name: String) throws -> Data { try fixture("src/\(name)") }

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

/// Builds a stored (method 0) archive; `declared` overrides the central-directory uncompressed size.
private func makeZip(_ items: [(name: String, data: Data, declared: UInt32?)], flags: Int = 0, method: Int = 0) -> Data {
    var out = Data()
    var central = Data()
    for it in items {
        let name = Array(it.name.utf8)
        let crc = ZipReader.crc32(it.data)
        let offset = UInt32(out.count)
        out += le32(0x0403_4b50) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0x21)
        out += le32(crc) + le32(UInt32(it.data.count)) + le32(UInt32(it.data.count))
        out += le16(name.count) + le16(0) + name + it.data
        central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0x21)
        central += le32(crc) + le32(UInt32(it.data.count)) + le32(it.declared ?? UInt32(it.data.count))
        central += le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
    }
    let cdOffset = UInt32(out.count)
    out += central
    out += le32(0x0605_4b50) + le16(0) + le16(0) + le16(items.count) + le16(items.count)
    out += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
    return out
}

private func patch(_ d: Data, at offset: Int, _ bytes: [UInt8]) -> Data {
    var d = d
    for (i, b) in bytes.enumerated() { d[offset + i] = b }
    return d
}

private func centralHeaderOffset(_ d: Data) -> Int {
    var i = 0
    while i + 4 <= d.count {
        if d[i] == 0x50, d[i + 1] == 0x4b, d[i + 2] == 0x01, d[i + 3] == 0x02 { return i }
        i += 1
    }
    return -1
}

@Suite struct ZipReaderTests {
    @Test func crcKnownValue() {
        #expect(ZipReader.crc32(Data("hello fritzing\n".utf8)) == 0x5587_d254)
    }

    @Test func readsStoredAndDeflated() throws {
        let stored = try ZipReader(data: fixture("stored.zip"))
        #expect(stored.entryNames == ["hello.txt", "blob.bin", "sub/nested.txt"])
        for n in stored.entryNames {
            #expect(try stored.data(for: n) == source(n))
        }

        let deflated = try ZipReader(data: fixture("deflated.zip"))
        #expect(deflated.entryNames == ["hello.txt", "repeat.txt", "blob.bin", "sub/nested.txt"])
        for n in deflated.entryNames {
            #expect(try deflated.data(for: n) == source(n))
        }
    }

    @Test func readsFromDataSlice() throws {
        let z = try fixture("deflated.zip")
        let padded = Data([1, 2, 3]) + z
        let r = try ZipReader(data: padded[3...])
        #expect(try r.data(for: "repeat.txt") == source("repeat.txt"))
    }

    @Test func rejectsTruncated() throws {
        let z = try fixture("stored.zip")
        #expect(throws: ZipError.notAZip) { try ZipReader(data: Data()) }
        #expect(throws: ZipError.notAZip) { try ZipReader(data: z.prefix(z.count - 10)) }
        #expect(throws: ZipError.notAZip) { try ZipReader(data: Data(repeating: 0x41, count: 100)) }
    }

    @Test func rejectsCorruptStructure() throws {
        let z = try fixture("stored.zip")
        let cd = centralHeaderOffset(z)
        // central-directory offset past EOF
        let eocd = z.count - 22
        #expect(throws: ZipError.corrupt("central directory range")) {
            try ZipReader(data: patch(z, at: eocd + 16, le32(UInt32(z.count))))
        }
        // local offset out of bounds -> data(for:) fails
        let badOff = try ZipReader(data: patch(z, at: cd + 42, le32(0x00FF_0000)))
        #expect(throws: ZipError.corrupt("local header")) { try badOff.data(for: "hello.txt") }
        // compressed size beyond data
        let badLen = try ZipReader(data: patch(z, at: cd + 20, le32(1_000_000)))
        #expect(throws: ZipError.corrupt("data range")) { try badLen.data(for: "hello.txt") }
    }

    @Test func rejectsUnsafePaths() {
        for bad in ["../evil", "a/../../evil", "/etc/passwd", "a/.."] {
            let z = makeZip([(bad, Data("x".utf8), nil)])
            #expect(throws: ZipError.unsafePath(bad)) { try ZipReader(data: z) }
        }
        // dots inside a component are fine
        #expect(throws: Never.self) { try ZipReader(data: makeZip([("a..b/c.txt", Data("x".utf8), nil)])) }
    }

    @Test func rejectsOversize() {
        let oneGB = makeZip([("big.bin", Data("x".utf8), 0x4000_0000)])
        #expect(throws: ZipError.tooLarge("big.bin")) { try ZipReader(data: oneGB) }

        let just = UInt32(ZipReader.maxEntrySize)
        #expect(throws: Never.self) { try ZipReader(data: makeZip([("ok.bin", Data("x".utf8), just)])) }
        let over = makeZip([("big.bin", Data("x".utf8), just + 1)])
        #expect(throws: ZipError.tooLarge("big.bin")) { try ZipReader(data: over) }

        // 6 x 19 MB = 114 MB total > 100 MB
        let many = makeZip((0..<6).map { ("f\($0).bin", Data("x".utf8), UInt32(19_000_000)) })
        #expect(throws: ZipError.tooLarge("archive")) { try ZipReader(data: many) }
    }

    @Test func rejectsBadCRC() throws {
        let z = try fixture("stored.zip")
        let cd = centralHeaderOffset(z)
        let r = try ZipReader(data: patch(z, at: cd + 16, [0, 0, 0, 0]))
        #expect(throws: ZipError.corrupt("crc mismatch hello.txt")) { try r.data(for: "hello.txt") }

        let d = try fixture("deflated.zip")
        // flip a byte inside the deflated payload of repeat.txt
        let local = try #require(d.range(of: Data("repeat.txt".utf8)))
        let r2 = try ZipReader(data: patch(d, at: local.upperBound + 4, [0xFF]))
        #expect(throws: ZipError.self) { try r2.data(for: "repeat.txt") }
    }

    @Test func rejectsEncryptedZip64AndMethods() {
        let item = [("a.txt", Data("x".utf8), UInt32?.none)]
        #expect(throws: ZipError.corrupt("encrypted")) { try ZipReader(data: makeZip(item, flags: 1)) }
        #expect(throws: ZipError.unsupportedMethod(99)) { try ZipReader(data: makeZip(item, method: 99)) }
        #expect(throws: ZipError.corrupt("zip64")) {
            try ZipReader(data: makeZip([("a.txt", Data("x".utf8), 0xFFFF_FFFF)]))
        }
        let z = makeZip(item)
        #expect(throws: ZipError.corrupt("zip64")) {
            try ZipReader(data: patch(z, at: z.count - 22 + 10, [0xFF, 0xFF]))
        }
    }

    @Test func rejectsDuplicateNames() {
        let z = makeZip([("a", Data("x".utf8), nil), ("a", Data("y".utf8), nil)])
        #expect(throws: ZipError.corrupt("duplicate entry")) { try ZipReader(data: z) }
    }
}
