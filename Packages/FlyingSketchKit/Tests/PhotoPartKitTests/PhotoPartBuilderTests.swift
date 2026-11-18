import CoreGraphics
import Foundation
import ImageIO
import PartsKit
import SketchCore
import Testing
@testable import PhotoPartKit

@Suite struct PhotoPartBuilderTests {
    static func source(_ w: Int, _ h: Int) -> SourceImage {
        SourceImage(image: PhotoFixtures.rgbImage(width: w, height: h) { _, _ in (255, 0, 0) })
    }

    static func decode(_ png: Data) -> CGImage? {
        guard let s = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    static func draft(_ w: Int, _ h: Int) -> PhotoPartDraft {
        var d = PhotoPartDraft(sourceSize: PixelSize(width: w, height: h))
        d.metadata.title = "Part"
        d.scale = .width(mm: Double(w) * 0.1)
        return d
    }

    static func pixel(_ png: Data, _ x: Int, _ y: Int) -> [UInt8] {
        let img = decode(png)!
        // Re-draw into a known RGBA layout.
        return PhotoFixtures.pixel(img, x: x, y: y)
    }

    @Test func rendersMaskedCrop() throws {
        var mask = MaskBitmap(width: 100, height: 50, filled: false)
        for y in 0..<50 { for x in 0..<50 { mask.bytes[y * 100 + x] = 255 } }
        let png = try PhotoPartBuilder.render(source: Self.source(100, 50), mask: mask, draft: Self.draft(100, 50))
        let img = try #require(Self.decode(png))
        #expect(img.width == 100 && img.height == 50)
        #expect(Self.pixel(png, 25, 25)[3] == 255)
        #expect(Self.pixel(png, 75, 25)[3] == 0)
    }

    @Test func quarterTurnRenderSwapsDimensions() throws {
        var d = Self.draft(100, 50)
        d.crop.quarterTurns = 1
        let png = try PhotoPartBuilder.render(source: Self.source(100, 50),
                                              mask: MaskBitmap(width: 100, height: 50, filled: true), draft: d)
        let img = try #require(Self.decode(png))
        #expect(img.width == 50 && img.height == 100)
        #expect(Self.pixel(png, 25, 50)[3] == 255)
    }

    @Test func quarterTurnMovesMaskedHalf() throws {
        // Mask = left half of source; rotated clockwise, left half becomes top half.
        var mask = MaskBitmap(width: 100, height: 50, filled: false)
        for y in 0..<50 { for x in 0..<50 { mask.bytes[y * 100 + x] = 255 } }
        var d = Self.draft(100, 50)
        d.crop.quarterTurns = 1
        let png = try PhotoPartBuilder.render(source: Self.source(100, 50), mask: mask, draft: d)
        #expect(Self.pixel(png, 25, 25)[3] == 255)
        #expect(Self.pixel(png, 25, 75)[3] == 0)
    }

    @Test func outputIsCappedAt2048() throws {
        let png = try PhotoPartBuilder.render(source: Self.source(100, 50),
                                              mask: MaskBitmap(width: 100, height: 50, filled: true),
                                              draft: {
            var d = Self.draft(100, 50)
            d.crop.size = Vec2(x: 4096, y: 1024)
            d.crop.center = Vec2(x: 50, y: 25)
            return d
        }())
        let img = try #require(Self.decode(png))
        #expect(img.width == 2048 && img.height == 512)
    }

    @Test func emptyMaskIsAnError() {
        #expect(throws: PhotoPartError.emptyMask) {
            _ = try PhotoPartBuilder.render(source: Self.source(100, 50),
                                            mask: MaskBitmap(width: 100, height: 50, filled: false),
                                            draft: Self.draft(100, 50))
        }
    }

    @Test func maskOutsideCropIsAnError() {
        var mask = MaskBitmap(width: 100, height: 50, filled: false)
        for y in 0..<50 { for x in 0..<20 { mask.bytes[y * 100 + x] = 255 } }
        var d = Self.draft(100, 50)
        d.crop = CropSpec(center: Vec2(x: 75, y: 25), size: Vec2(x: 40, y: 50))
        #expect(throws: PhotoPartError.emptyMask) {
            _ = try PhotoPartBuilder.render(source: Self.source(100, 50), mask: mask, draft: d)
        }
    }

    @Test func definitionUsesMillimetres() throws {
        var d = Self.draft(1000, 600)
        d.crop = CropSpec(center: Vec2(x: 500, y: 300), size: Vec2(x: 500, y: 300))
        d.scale = .width(mm: 50)
        let id = d.addPin(atOutput: Vec2(x: 100, y: 100))
        let part = try PhotoPartBuilder.build(source: Self.source(1000, 600),
                                              mask: MaskBitmap(width: 1000, height: 600, filled: true), draft: d)
        let def = part.definition
        #expect(abs(def.size.x - 50) < 1e-9 && abs(def.size.y - 30) < 1e-9)
        let c = try #require(def.connectors.first)
        #expect(c.id == id)
        #expect(abs(c.position.x - 10) < 1e-6 && abs(c.position.y - 10) < 1e-6)
    }

    @Test func pinOutsideCropIsAnError() {
        var d = Self.draft(100, 50)
        d.pins = [DraftPin(id: "a", name: "VCC", position: Vec2(x: 500, y: 10))]
        #expect(throws: PhotoPartError.pinOutside("VCC")) { try PhotoPartBuilder.validate(d) }
    }

    @Test func duplicatePinNamesRejected() {
        var d = Self.draft(100, 50)
        d.pins = [DraftPin(id: "a", name: "GND", position: Vec2(x: 5, y: 10)),
                  DraftPin(id: "b", name: "gnd", position: Vec2(x: 10, y: 10))]
        #expect(throws: PhotoPartError.duplicatePinName("gnd")) { try PhotoPartBuilder.validate(d) }
    }

    @Test func validationOrderAndBuses() {
        var d = Self.draft(100, 50)
        d.metadata.title = "  "
        #expect(throws: PhotoPartError.emptyTitle) { try PhotoPartBuilder.validate(d) }
        d.metadata.title = "x"
        d.pins = [DraftPin(id: "a", name: " ", position: Vec2(x: 5, y: 10)),
                  DraftPin(id: "b", name: "B", position: Vec2(x: 10, y: 10))]
        #expect(throws: PhotoPartError.emptyPinName("a")) { try PhotoPartBuilder.validate(d) }
        d.pins[0].name = "A"
        d.buses = [["a", "zz"]]
        #expect(throws: PhotoPartError.unknownBusMember("zz")) { try PhotoPartBuilder.validate(d) }
        d.buses = [["a", "b"], ["b", "a"]]
        #expect(throws: PhotoPartError.pinInTwoBuses("b")) { try PhotoPartBuilder.validate(d) }
        d.buses = []
        d.scale = nil
        #expect(throws: PhotoPartError.missingScale) { try PhotoPartBuilder.validate(d) }
        d.scale = .width(mm: 1_000_000)
        #expect(throws: PhotoPartError.partTooLarge) { try PhotoPartBuilder.validate(d) }
    }

    @Test func versionHashChangesWithPins() throws {
        let src = Self.source(100, 50), mask = MaskBitmap(width: 100, height: 50, filled: true)
        var d = Self.draft(100, 50)
        let a = try PhotoPartBuilder.build(source: src, mask: mask, draft: d)
        d.addPin(atOutput: Vec2(x: 10, y: 10))
        let b = try PhotoPartBuilder.build(source: src, mask: mask, draft: d)
        #expect(a.definition.versionHash != b.definition.versionHash)
    }

    @Test func builtPartIsValid() throws {
        var d = Self.draft(100, 50)
        d.addPin(atOutput: Vec2(x: 10, y: 10))
        let part = try PhotoPartBuilder.build(source: Self.source(100, 50),
                                              mask: MaskBitmap(width: 100, height: 50, filled: true), draft: d)
        try part.definition.validate()
        #expect(part.definition.graphicKind == .png)
        #expect(part.definition.graphicAsset == "part-\(part.definition.versionHash).png")
        #expect(part.source == .personal)
        let img = try #require(Self.decode(part.graphic))
        #expect(img.width == 100 && img.height == 50)
    }
}
