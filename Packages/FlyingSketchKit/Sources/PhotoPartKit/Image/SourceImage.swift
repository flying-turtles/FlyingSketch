import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PhotoPartError: Error, Equatable, Sendable {
    case undecodableImage, emptyMask, traceTooShort, missingScale, calibrationTooShort
    case invalidDistance, partTooLarge
    case pinOutside(String), emptyPinName(String), duplicatePinName(String)
    case unknownBusMember(String), pinInTwoBuses(String)
    case emptyTitle, maskSizeMismatch, cutoutUnavailable, noForeground
}

public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Decoded, upright, size-capped photo as 8-bit premultiplied RGBA sRGB.
public struct SourceImage: Sendable {
    public static let maxEdge = 2048
    /// Larger headers are rejected before decoding (decompression-bomb guard).
    public static let maxSourcePixels = 100_000_000

    public let image: CGImage

    public var pixelSize: PixelSize { PixelSize(width: image.width, height: image.height) }

    public static func load(_ data: Data) throws(PhotoPartError) -> SourceImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            throw .undecodableImage
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            guard w > 0, h > 0, w.multipliedReportingOverflow(by: h).overflow == false,
                  w * h <= maxSourcePixels else { throw .undecodableImage }
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary),
              decoded.width > 0, decoded.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: decoded.width, height: decoded.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw .undecodableImage }
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let image = ctx.makeImage() else { throw .undecodableImage }
        return SourceImage(image: image)
    }

    public func pngData() -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
