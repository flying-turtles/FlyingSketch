import CoreGraphics
import Foundation
import ImageIO
import SketchCore
import UniformTypeIdentifiers

/// Inclusive pixel bounds.
public struct PixelRect: Hashable, Sendable {
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int

    public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

/// Binary mask, row-major, 0 or 255, origin top-left.
public struct MaskBitmap: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, filled: Bool) {
        self.width = width
        self.height = height
        self.bytes = [UInt8](repeating: filled ? 255 : 0, count: max(0, width * height))
    }

    public func value(at p: Vec2) -> Bool {
        let x = Int(p.x.rounded(.down)), y = Int(p.y.rounded(.down))
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bytes[y * width + x] != 0
    }

    public mutating func stroke(_ points: [Vec2], radius: Double, add: Bool) {
        guard let first = points.first, radius > 0 else { return }
        stamp(first, radius: radius, add: add)
        let step = radius / 2
        for (a, b) in zip(points, points.dropFirst()) {
            let len = a.distance(to: b)
            let n = max(1, Int((len / step).rounded(.up)))
            for i in 1...n { stamp(a + (b - a) * (Double(i) / Double(n)), radius: radius, add: add) }
        }
    }

    private mutating func stamp(_ c: Vec2, radius: Double, add: Bool) {
        let x0 = max(0, Int((c.x - radius).rounded(.down)))
        let x1 = min(width - 1, Int((c.x + radius).rounded(.up)))
        let y0 = max(0, Int((c.y - radius).rounded(.down)))
        let y1 = min(height - 1, Int((c.y + radius).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        let r2 = radius * radius
        let v: UInt8 = add ? 255 : 0
        for y in y0...y1 {
            let dy = Double(y) + 0.5 - c.y
            for x in x0...x1 {
                let dx = Double(x) + 0.5 - c.x
                if dx * dx + dy * dy <= r2 { bytes[y * width + x] = v }
            }
        }
    }

    /// Replaces the mask with the even-odd fill of `points`.
    public mutating func fillPolygon(_ points: [Vec2]) throws(PhotoPartError) {
        guard points.count >= 3 else { throw .traceTooShort }
        bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let yc = Double(y) + 0.5
            var xs: [Double] = []
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                guard (a.y <= yc) != (b.y <= yc) else { continue }
                xs.append(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x))
            }
            xs.sort()
            var i = 0
            while i + 1 < xs.count {
                let start = max(0, Int((xs[i] - 0.5).rounded(.up)))
                let end = min(width, Int((xs[i + 1] - 0.5).rounded(.up)))
                if start < end { for x in start..<end { bytes[y * width + x] = 255 } }
                i += 2
            }
        }
    }

    public mutating func formUnion(_ other: MaskBitmap) throws(PhotoPartError) {
        guard other.width == width, other.height == height else { throw .maskSizeMismatch }
        for i in bytes.indices where other.bytes[i] != 0 { bytes[i] = 255 }
    }

    public var boundingBox: PixelRect? {
        var box: PixelRect?
        for y in 0..<height {
            for x in 0..<width where bytes[y * width + x] != 0 {
                if var b = box {
                    b.minX = min(b.minX, x); b.maxX = max(b.maxX, x)
                    b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
                    box = b
                } else {
                    box = PixelRect(minX: x, minY: y, maxX: x, maxY: y)
                }
            }
        }
        return box
    }

    /// 8-bit DeviceGray PNG.
    public func pngData() -> Data {
        var copy = bytes
        let image: CGImage? = copy.withUnsafeMutableBytes { buf in
            CGContext(
                data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        let out = NSMutableData()
        guard let image,
              let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    public static func decode(png: Data, expected: PixelSize) throws(PhotoPartError) -> MaskBitmap {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw .undecodableImage }
        guard image.width == expected.width, image.height == expected.height else { throw .maskSizeMismatch }
        var mask = MaskBitmap(width: image.width, height: image.height, filled: false)
        let w = image.width, h = image.height
        let ok: Bool = mask.bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw .undecodableImage }
        for i in mask.bytes.indices { mask.bytes[i] = mask.bytes[i] >= 128 ? 255 : 0 }
        return mask
    }
}
