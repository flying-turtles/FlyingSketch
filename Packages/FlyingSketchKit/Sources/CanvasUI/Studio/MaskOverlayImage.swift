import CoreGraphics
import Foundation
import PhotoPartKit

/// Builds opaque-colour/transparent CGImages from a mask, for overlay layers (opacity set on the layer).
/// One pass over the bytes per call; callers regenerate only when the mask changes.
enum MaskOverlayImage {
    struct RGB: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

    static let black = RGB(r: 0, g: 0, b: 0)
    /// Distinct instance-candidate hues (cycled).
    static let instanceHues: [RGB] = [
        RGB(r: 255, g: 59, b: 48), RGB(r: 0, g: 122, b: 255), RGB(r: 52, g: 199, b: 89),
        RGB(r: 255, g: 149, b: 0), RGB(r: 175, g: 82, b: 222),
    ]

    /// Pixels where `mask` is set (or unset when `inside == false`) become `color`, the rest transparent.
    static func make(_ mask: MaskBitmap, inside: Bool, color: RGB) -> CGImage? {
        guard mask.width > 0, mask.height > 0 else { return nil }
        // byteOrder32Little + premultipliedFirst: native UInt32 is ARGB. Alpha is 0 or 255, so no premultiply.
        let on = UInt32(0xFF00_0000) | UInt32(color.r) << 16 | UInt32(color.g) << 8 | UInt32(color.b)
        let pixels: [UInt32] = inside
            ? mask.bytes.map { $0 != 0 ? on : 0 }
            : mask.bytes.map { $0 == 0 ? on : 0 }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: mask.width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
