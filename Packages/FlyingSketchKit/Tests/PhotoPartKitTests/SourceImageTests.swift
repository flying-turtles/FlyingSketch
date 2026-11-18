import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotoPartKit

enum PhotoFixtures {
    /// Builds an 8-bit RGBA image, colouring each pixel via `color(x, y)`.
    static func rgbImage(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let c = color(x, y), i = (y * width + x) * 4
            px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
        } }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, orientation: Int? = nil) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func gray16PNG(width: Int, height: Int) -> Data {
        var px = [UInt16](repeating: 0x8000, count: width * height)
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 2,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return encode(ctx.makeImage()!, type: .png)
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px
    }
}

@Suite struct SourceImageTests {
    @Test func normalizesOrientationSizeAndFormat() throws {
        // 4000x1000 stored; top-left stored = red, bottom-left stored = blue, rest green.
        let img = PhotoFixtures.rgbImage(width: 4000, height: 1000) { x, y in
            if x < 100 && y < 100 { return (255, 0, 0) }
            if x < 100 && y >= 900 { return (0, 0, 255) }
            return (0, 255, 0)
        }
        let jpeg = PhotoFixtures.encode(img, type: .jpeg, orientation: 6)
        let loaded = try SourceImage.load(jpeg)
        #expect(loaded.pixelSize == PixelSize(width: 512, height: 2048))
        #expect(loaded.image.width == 512 && loaded.image.height == 2048)
        #expect(loaded.image.bitsPerComponent == 8)
        #expect(loaded.image.bitsPerPixel == 32)
        // Orientation 6 = rotate 90 CW: stored bottom-left ends up at top-left.
        let p = PhotoFixtures.pixel(loaded.image, x: 2, y: 2)
        #expect(p[2] > 200 && p[0] < 60)
    }

    @Test func gray16PNGBecomesRGBA8() throws {
        let loaded = try SourceImage.load(PhotoFixtures.gray16PNG(width: 32, height: 16))
        #expect(loaded.image.bitsPerComponent == 8)
        #expect(loaded.image.bitsPerPixel == 32)
        #expect(loaded.image.alphaInfo == .premultipliedLast)
        #expect(loaded.pixelSize == PixelSize(width: 32, height: 16))
        #expect(!loaded.pngData().isEmpty)
    }

    @Test func garbageThrows() {
        #expect(throws: PhotoPartError.undecodableImage) {
            try SourceImage.load(Data([1, 2, 3, 4, 5]))
        }
    }
}
