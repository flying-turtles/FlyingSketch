import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import SketchCore
@testable import ExportKit

private let bounds = Rect(origin: .zero, size: Vec2(x: 40, y: 45))
private let ppm = 10.0
private let center = Vec2(x: 20, y: 20)

private let redBlueSVG = Data("""
<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="4mm" viewBox="0 0 10 4">\
<rect width="5" height="4" fill="#ff0000"/><rect x="5" width="5" height="4" fill="#0000ff"/></svg>
""".utf8)

private func px(_ img: CGImage, _ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double, a: Double) {
    pixel(img, mmX: x, mmY: y, bounds: bounds, pxPerMM: ppm)
}

private func isRed(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { c.r > 0.9 && c.g < 0.25 && c.b < 0.25 }
private func isBlue(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { c.b > 0.9 && c.r < 0.25 && c.g < 0.25 }
/// Leg colour is gray 0.7 (0.75 after colour-space conversion): neither white nor body red/blue/black.
private func isLegGray(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool {
    abs(c.r - c.g) < 0.03 && abs(c.g - c.b) < 0.03 && c.r > 0.6 && c.r < 0.85
}
private func isWhite(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { c.r > 0.95 && c.g > 0.95 && c.b > 0.95 }

/// Resistor definition resized to the 10x4 test graphic, with the given asset bytes.
private func scene(kind: GraphicKind = .svg, asset: Data = redBlueSVG, quarterTurns: Int = 0, angle: Double? = nil,
                   legEnds: [String: Vec2] = [:], legs: Bool = false) -> ExportContent {
    var f = Fix()
    var def = f.res
    def.size = Vec2(x: 10, y: 4)
    def.graphicKind = kind
    if !legs { def.connectors = [] }
    f.doc.parts[def.key] = def
    f.doc.assets[def.graphicAsset] = asset
    f.add(def, at: center, rotation: angle ?? Double(quarterTurns) * .pi / 2, legEnds: legEnds)
    return ExportContent(document: f.doc, objects: f.doc.objects, bounds: bounds)
}

/// 20x8 PNG, left half red, right half blue (large enough that smoothing stays away from the 18/22 mm samples).
private func redBluePNG() -> Data {
    let ctx = CGContext(data: nil, width: 20, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 8))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 10, y: 0, width: 10, height: 8))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

private func expectLeftRed(_ img: CGImage) {
    #expect(isRed(px(img, 18, 20)))
    #expect(isBlue(px(img, 22, 20)))
    #expect(isWhite(px(img, 26, 20)))
}

@Test func svgPartDrawsAtCenter() {
    expectLeftRed(render(scene(), pxPerMM: ppm))
}

@Test func quarterTurnRotatesPart() {
    let q1 = render(scene(quarterTurns: 1), pxPerMM: ppm)
    #expect(isRed(px(q1, 20, 18)))
    #expect(isBlue(px(q1, 20, 22)))
    let q3 = render(scene(quarterTurns: 3), pxPerMM: ppm)
    #expect(isBlue(px(q3, 20, 18)))
    #expect(isRed(px(q3, 20, 22)))
    // Normalised mod 4: -1 equals 3.
    let qm = render(scene(quarterTurns: -1), pxPerMM: ppm)
    #expect(isBlue(px(qm, 20, 18)))
}

@Test func pngPartDraws() {
    expectLeftRed(render(scene(kind: .png, asset: redBluePNG()), pxPerMM: ppm))
}

@Test func legsDrawToTheirEnds() {
    let img = render(scene(legEnds: ["a": Vec2(x: 20, y: 35)], legs: true), pxPerMM: ppm)
    // Leg a: origin (15, 19.25) (local (0, 1.25) of the 10x4 body) -> (20, 35); at y = 30 it passes x = 18.41.
    let p = px(img, 18.41, 30)
    #expect(isLegGray(p))
    #expect(isWhite(px(img, 22, 30)))
}

@Test func legsDrawAboveBody() {
    let img = render(scene(legEnds: ["a": center], legs: true), pxPerMM: ppm)
    // Leg a runs (15, 19.25) -> (20, 20) across the red half; at x = 17 it is at y = 19.55.
    let p = px(img, 17, 19.55)
    #expect(isLegGray(p))
}

@Test func brokenPartsDrawPlaceholder() {
    func topEdgeInk(_ c: ExportContent) -> Bool {
        let img = render(c, pxPerMM: ppm)
        // Placeholder is a 10 mm square centred on (20, 20): top edge at y = 15; dashes leave gaps, so scan.
        for x in stride(from: 15.0, through: 25.0, by: 0.1) where !isWhite(px(img, x, 15)) { return true }
        return false
    }
    // Missing definition.
    var doc = SketchDocument()
    doc.objects.append(.part(PartInstance(definitionKey: "nope@v1", center: center)))
    #expect(topEdgeInk(ExportContent(document: doc, objects: doc.objects, bounds: bounds)))
    // Invalid SVG, undecodable PNG.
    #expect(topEdgeInk(scene(asset: Data("not svg".utf8))))
    #expect(topEdgeInk(scene(kind: .png, asset: Data([1, 2, 3]))))
    // Missing asset.
    var f = Fix()
    f.add(f.res, at: center)
    #expect(topEdgeInk(ExportContent(document: f.doc, objects: f.doc.objects, bounds: bounds)))
}

@Test func brokenGraphicStillDrawsLegs() {
    let img = render(scene(asset: Data("not svg".utf8), legEnds: ["a": Vec2(x: 20, y: 35)], legs: true), pxPerMM: ppm)
    #expect(isLegGray(px(img, 18.41, 30)))
}

@Test func partRotatesClockwiseNotCounterClockwise() {
    let img = render(scene(kind: .png, asset: redBluePNG(), angle: .pi / 6), pxPerMM: ppm)
    let red = center + Vec2(x: -4, y: 0).rotated(by: .pi / 6)   // left (red) half, turned clockwise
    let mirror = center + Vec2(x: -4, y: 0).rotated(by: -.pi / 6)
    #expect(isRed(px(img, red.x, red.y)))
    #expect(isWhite(px(img, mirror.x, mirror.y)))
}
