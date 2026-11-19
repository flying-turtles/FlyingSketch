import Foundation
import Testing
@testable import SketchCore

@Suite struct SceneGeometryTests {
    @Test func arrowBarbsMatchCanvasFormula() throws {
        let s = ShapeObject(kind: .arrow, start: Vec2(x: 0, y: 0), end: Vec2(x: 10, y: 0), lineWidth: 0.5)
        let (a, b) = try #require(ShapeGeometry.arrowBarbs(of: s))
        let head = 4.0 // max(0.5*5, 4)
        #expect(abs(a.x - (10 - head * cos(0.45))) < 1e-9)
        #expect(abs(abs(a.y) - head * sin(0.45)) < 1e-9)
        #expect(abs(a.y + b.y) < 1e-9)          // symmetric
        #expect(ShapeGeometry.arrowBarbs(of: ShapeObject(kind: .line, start: .zero, end: Vec2(x: 1, y: 0))) == nil)
        #expect(ShapeGeometry.arrowBarbs(of: ShapeObject(kind: .arrow, start: .zero, end: .zero)) == nil)
    }

    @Test func shapeRectIsNormalised() {
        let s = ShapeObject(kind: .rectangle, start: Vec2(x: 10, y: 8), end: Vec2(x: 2, y: 3))
        #expect(ShapeGeometry.rect(of: s) == Rect(origin: Vec2(x: 2, y: 3), size: Vec2(x: 8, y: 5)))
    }

    @Test func contentBoundsIncludesFreeWireEnds() throws {
        let w = Wire(start: WireEnd(position: Vec2(x: 0, y: 0)), end: WireEnd(position: Vec2(x: 10, y: 0)), width: 0.65)
        let doc = SketchDocument(objects: [.wire(w)])
        let r = try #require(contentBounds(of: doc.objects, in: doc))
        #expect(abs(r.minX - (-(0.6 + 0.325))) < 1e-9)
        #expect(contentBounds(of: [], in: doc) == nil)
    }
}
