import Foundation

/// Minimal ZIP writer: stored (method 0) entries, UTF-8 names, no ZIP64. Output is readable by `ZipReader`.
public struct ZipWriter {
    private struct Item {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var body = Data()
    private var items: [Item] = []

    public init() {}

    public mutating func add(_ name: String, data: Data) {
        let nameBytes = Array(name.utf8)
        let crc = ZipReader.crc32(data)
        let item = Item(name: nameBytes, crc: crc, size: UInt32(truncatingIfNeeded: data.count),
                        offset: UInt32(truncatingIfNeeded: body.count))
        body.appendU32(0x0403_4b50)
        body.appendU16(20)  // version needed
        body.appendU16(0x0800)  // UTF-8 names
        body.appendU16(0)  // stored
        body.appendU16(0)  // dos time
        body.appendU16(0x21)  // dos date 1980-01-01
        body.appendU32(crc)
        body.appendU32(item.size)
        body.appendU32(item.size)
        body.appendU16(UInt16(truncatingIfNeeded: nameBytes.count))
        body.appendU16(0)  // extra
        body.append(contentsOf: nameBytes)
        body.append(data)
        items.append(item)
    }

    public func finish() -> Data {
        var out = body
        let cdStart = out.count
        for it in items {
            out.appendU32(0x0201_4b50)
            out.appendU16(20)  // made by
            out.appendU16(20)  // needed
            out.appendU16(0x0800)
            out.appendU16(0)
            out.appendU16(0)
            out.appendU16(0x21)
            out.appendU32(it.crc)
            out.appendU32(it.size)
            out.appendU32(it.size)
            out.appendU16(UInt16(truncatingIfNeeded: it.name.count))
            out.appendU16(0)  // extra
            out.appendU16(0)  // comment
            out.appendU16(0)  // disk
            out.appendU16(0)  // internal attrs
            out.appendU32(0)  // external attrs
            out.appendU32(it.offset)
            out.append(contentsOf: it.name)
        }
        let cdSize = out.count - cdStart
        out.appendU32(0x0605_4b50)
        out.appendU16(0)
        out.appendU16(0)
        out.appendU16(UInt16(truncatingIfNeeded: items.count))
        out.appendU16(UInt16(truncatingIfNeeded: items.count))
        out.appendU32(UInt32(truncatingIfNeeded: cdSize))
        out.appendU32(UInt32(truncatingIfNeeded: cdStart))
        out.appendU16(0)
        return out
    }
}

private extension Data {
    mutating func appendU16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func appendU32(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
}
