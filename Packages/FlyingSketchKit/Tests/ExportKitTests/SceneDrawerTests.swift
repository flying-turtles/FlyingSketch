import CoreGraphics
import Foundation
import Testing
import SketchCore
@testable import ExportKit

private let bounds = Rect(origin: .zero, size: Vec2(x: 40, y: 30))
private let ppm = 10.0

private func content(_ objects: [SceneObject], assets: [String: Data] = [:]) -> ExportContent {
    var doc = SketchDocument()
    doc.assets = assets
    doc.objects = objects
    return ExportContent(document: doc, objects: objects, bounds: bounds)
}

private func px(_ img: CGImage, _ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double, a: Double) {
    pixel(img, mmX: x, mmY: y, bounds: bounds, pxPerMM: ppm)
}

private func stroke(_ a: Vec2, _ b: Vec2, tool: InkTool = .pen, color: RGBAColor = .black, width: Double = 2) -> SceneObject {
    .ink(InkStroke(points: [InkPoint(position: a, pressure: 1, time: 0), InkPoint(position: b, pressure: 1, time: 0.1)],
                   tool: tool, color: color, baseWidth: width))
}

/// True when any pixel in the mm region is dark.
private func anyDark(_ img: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Bool {
    for xi in stride(from: x.lowerBound, through: x.upperBound, by: 0.1) {
        for yi in stride(from: y.lowerBound, through: y.upperBound, by: 0.1) where px(img, xi, yi).r < 0.5 { return true }
    }
    return false
}

@Test func inkStrokeFillsItsOutline() {
    let img = render(content([stroke(Vec2(x: 10, y: 10), Vec2(x: 30, y: 10))]), pxPerMM: ppm)
    #expect(px(img, 20, 10).r < 0.2)
    #expect(px(img, 20, 14).r > 0.9)
}

@Test func highlighterMultiplies() {
    let red = RGBAColor(r: 1, g: 0, b: 0)
    let rect = SceneObject.shape(ShapeObject(kind: .rectangle, start: Vec2(x: 5, y: 5), end: Vec2(x: 35, y: 25),
                                             strokeColor: red, fillColor: red, lineWidth: 0.5))
    let hl = stroke(Vec2(x: 10, y: 15), Vec2(x: 30, y: 15), tool: .highlighter, color: RGBAColor(r: 1, g: 1, b: 0), width: 4)
    let p = px(render(content([rect, hl]), pxPerMM: ppm), 20, 15)
    #expect(p.r > 0.8)
    #expect(p.g < 0.2)
}

@Test func arrowDrawsBarbs() throws {
    let s = ShapeObject(kind: .arrow, start: Vec2(x: 0, y: 0), end: Vec2(x: 20, y: 0), lineWidth: 0.5)
    let (b1, _) = try #require(ShapeGeometry.arrowBarbs(of: s))
    let mid = Vec2(x: (b1.x + 20) / 2, y: b1.y / 2)
    let c = ExportContent(document: SketchDocument(), objects: [.shape(s)], bounds: Rect(origin: Vec2(x: -5, y: -10), size: Vec2(x: 40, y: 30)))
    let img = render(c, pxPerMM: ppm)
    #expect(pixel(img, mmX: mid.x, mmY: mid.y, bounds: c.bounds, pxPerMM: ppm).r < 0.3)
}

@Test func wireFreeEndCircle() {
    // Thin wire so the 0.6 mm ring is distinguishable from the line at 10 px/mm.
    let attached = WireAttachment.connector(part: ObjectID.new(), connector: "a")
    let w = Wire(start: WireEnd(position: Vec2(x: 10, y: 10)),
                 end: WireEnd(position: Vec2(x: 30, y: 10), attachment: attached), width: 0.2)
    let img = render(content([.wire(w)]), pxPerMM: ppm)
    #expect(px(img, 10, 10.6).r < 0.3)    // ring below the line
    #expect(px(img, 10, 9.4).r < 0.3)     // ring above the line
    #expect(px(img, 10, 10.3).r > 0.9)    // inside ring, off the line: not filled
    #expect(px(img, 30, 10.6).r > 0.9)    // attached end: no ring
    #expect(px(img, 30, 9.4).r > 0.9)
}

@Test func textDrawsBelowAndRightOfPosition() {
    let t = TextObject(text: "H", position: Vec2(x: 10, y: 10), fontSize: 10)
    let img = render(content([.text(t)]), pxPerMM: ppm)
    #expect(anyDark(img, x: 10...17, y: 10...20))
    #expect(!anyDark(img, x: 0...39, y: 0...9.5))
    #expect(!anyDark(img, x: 0...9.5, y: 0...29))
}

@Test func rotatedTextTurnsClockwise() {
    let t = TextObject(text: "H", position: Vec2(x: 10, y: 10), fontSize: 10, rotation: .pi / 2)
    let img = render(content([.text(t)]), pxPerMM: ppm)
    #expect(anyDark(img, x: 0...10, y: 10...17))
    #expect(!anyDark(img, x: 10.5...39, y: 0...29))
}

@Test func imageObjectDrawsRotated() {
    let i = ImageObject(assetName: "a.png", frame: Rect(origin: Vec2(x: 10, y: 10), size: Vec2(x: 20, y: 10)), rotation: .pi)
    let img = render(content([.image(i)], assets: ["a.png": twoPixelPNG()]), pxPerMM: ppm)
    let l = px(img, 14, 15), r = px(img, 26, 15)
    #expect(l.b > 0.8 && l.r < 0.2)
    #expect(r.r > 0.8 && r.b < 0.2)
}

@Test func missingImageIsSkipped() {
    let i = ImageObject(assetName: "nope.png", frame: Rect(origin: Vec2(x: 10, y: 10), size: Vec2(x: 20, y: 10)))
    let img = render(content([.image(i), stroke(Vec2(x: 10, y: 20), Vec2(x: 30, y: 20))]), pxPerMM: ppm)
    #expect(px(img, 20, 20).r < 0.2)
    #expect(px(img, 20, 15).r > 0.9)
}
