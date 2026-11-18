import CoreVideo
import Foundation
import SketchCore
import Testing
@testable import PhotoPartKit

@Suite struct ForegroundCutoutTests {
    private func makeBuffer(width: Int, height: Int, format: OSType, fill: (UnsafeMutableRawPointer, Int) -> Void) -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &buf)
        let b = buf!
        CVPixelBufferLockBaseAddress(b, [])
        fill(CVPixelBufferGetBaseAddress(b)!, CVPixelBufferGetBytesPerRow(b))
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    @Test func maskFromFloatBuffer() {
        let rows: [[Float]] = [[0, 1, 0.4, 0.6], [0.5, 0.49, 1, 0]]
        let b = makeBuffer(width: 4, height: 2, format: kCVPixelFormatType_OneComponent32Float) { base, bpr in
            for (y, row) in rows.enumerated() {
                let p = (base + y * bpr).assumingMemoryBound(to: Float.self)
                for (x, v) in row.enumerated() { p[x] = v }
            }
        }
        let m = VisionCutout.mask(from: b)
        #expect(m.width == 4 && m.height == 2)
        #expect(m.bytes == [0, 255, 0, 255, 255, 0, 255, 0])
    }

    @Test func maskFromByteBuffer() {
        let rows: [[UInt8]] = [[0, 255, 127, 128], [128, 1, 200, 0]]
        let b = makeBuffer(width: 4, height: 2, format: kCVPixelFormatType_OneComponent8) { base, bpr in
            for (y, row) in rows.enumerated() {
                let p = (base + y * bpr).assumingMemoryBound(to: UInt8.self)
                for (x, v) in row.enumerated() { p[x] = v }
            }
        }
        let m = VisionCutout.mask(from: b)
        #expect(m.bytes == [0, 255, 0, 255, 255, 0, 255, 0])
    }

    @Test func unsupportedFormatGivesEmptyMask() {
        let b = makeBuffer(width: 3, height: 2, format: kCVPixelFormatType_32BGRA) { _, _ in }
        let m = VisionCutout.mask(from: b)
        #expect(m.width == 3 && m.height == 2)
        #expect(m.bytes == [UInt8](repeating: 0, count: 6))
    }

    @Test func instanceIndexPicksContainingMask() {
        var a = MaskBitmap(width: 4, height: 4, filled: false)
        var b = MaskBitmap(width: 4, height: 4, filled: false)
        a.bytes[0] = 255
        b.bytes[3 * 4 + 3] = 255
        #expect(instanceIndex(at: Vec2(x: 0.5, y: 0.5), in: [a, b]) == 0)
        #expect(instanceIndex(at: Vec2(x: 3.5, y: 3.5), in: [a, b]) == 1)
        #expect(instanceIndex(at: Vec2(x: 2, y: 2), in: [a, b]) == nil)
    }

    @Test func visionOnSyntheticImageIsTyped() async throws {
        let img = PhotoFixtures.rgbImage(width: 200, height: 200) { x, y in
            let dx = x - 100, dy = y - 100
            return dx * dx + dy * dy < 60 * 60 ? (220, 20, 20) : (255, 255, 255)
        }
        let source = SourceImage(image: img)
        do {
            let masks = try await VisionCutout().instances(in: source)
            #expect(!masks.isEmpty)
            var union = MaskBitmap(width: 200, height: 200, filled: false)
            for m in masks { try union.formUnion(m) }
            #expect(union.value(at: Vec2(x: 100, y: 100)))
        } catch let e as PhotoPartError {
            #expect(e == .cutoutUnavailable || e == .noForeground)
        }
    }
}
