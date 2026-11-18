import Foundation
import SketchCore
import Testing
@testable import PhotoPartKit

@Suite struct MaskBitmapTests {
    private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

    @Test func strokeAddsAndErases() {
        var m = MaskBitmap(width: 100, height: 100, filled: false)
        m.stroke([v(10, 50), v(90, 50)], radius: 5, add: true)
        #expect(m.value(at: v(50, 50)))
        #expect(!m.value(at: v(50, 60)))
        m.stroke([v(40, 50), v(60, 50)], radius: 5, add: false)
        #expect(!m.value(at: v(50, 50)))
        #expect(m.value(at: v(20, 50)))
    }

    @Test func polygonFillEvenOdd() throws {
        var m = MaskBitmap(width: 100, height: 100, filled: false)
        try m.fillPolygon([v(20, 20), v(80, 20), v(80, 80), v(20, 80)])
        #expect(m.value(at: v(50, 50)))
        #expect(!m.value(at: v(10, 50)))

        // Pentagram: centre pentagon is empty under even-odd.
        var star: [Vec2] = []
        for k in 0..<5 {
            let a = -Double.pi / 2 + Double(k * 2) * 2 * Double.pi / 5
            star.append(v(50 + 40 * cos(a), 50 + 40 * sin(a)))
        }
        try m.fillPolygon(star)
        #expect(!m.value(at: v(50, 50)))
        #expect(m.value(at: v(50, 15)))  // top tip

        #expect(throws: PhotoPartError.traceTooShort) {
            try m.fillPolygon([v(1, 1), v(5, 5)])
        }
    }

    @Test func boundingBoxAndEmpty() {
        var m = MaskBitmap(width: 50, height: 40, filled: false)
        #expect(m.boundingBox == nil)
        m.bytes[5 * 50 + 7] = 255
        m.bytes[20 * 50 + 30] = 255
        #expect(m.boundingBox == PixelRect(minX: 7, minY: 5, maxX: 30, maxY: 20))
        #expect(MaskBitmap(width: 4, height: 3, filled: true).boundingBox == PixelRect(minX: 0, minY: 0, maxX: 3, maxY: 2))
    }

    @Test func unionAndSizeMismatch() throws {
        var a = MaskBitmap(width: 10, height: 10, filled: false)
        var b = MaskBitmap(width: 10, height: 10, filled: false)
        b.bytes[0] = 255
        try a.formUnion(b)
        #expect(a.bytes[0] == 255)
        #expect(throws: PhotoPartError.maskSizeMismatch) {
            try a.formUnion(MaskBitmap(width: 5, height: 5, filled: false))
        }
    }

    @Test func maskPNGRoundTrip() throws {
        var m = MaskBitmap(width: 64, height: 48, filled: false)
        m.stroke([v(10, 10), v(50, 30)], radius: 4, add: true)
        let png = m.pngData()
        let back = try MaskBitmap.decode(png: png, expected: PixelSize(width: 64, height: 48))
        #expect(back == m)
        #expect(throws: PhotoPartError.maskSizeMismatch) {
            try MaskBitmap.decode(png: png, expected: PixelSize(width: 10, height: 10))
        }
    }
}
