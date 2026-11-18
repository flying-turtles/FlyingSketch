import Testing
import SketchCore
@testable import InkEngine

private func pt(_ x: Double, _ y: Double, _ p: Double = 1) -> InkPoint {
    InkPoint(position: Vec2(x: x, y: y), pressure: p, altitude: nil, azimuth: nil, time: 0)
}

@Test func singleSampleProducesDot() {
    let poly = StrokeOutline.polygon([pt(0, 0)], baseWidth: 2, tool: .pen)
    #expect(poly.count >= 12)
    #expect(poly.allSatisfy { abs($0.length - 1) < 1e-6 })
}

@Test func outlineIsClosedAndContainsCenterline() {
    let poly = StrokeOutline.polygon([pt(0, 0), pt(10, 0)], baseWidth: 2, tool: .pen)
    let r = 1.0
    let xs = poly.map(\.x), ys = poly.map(\.y)
    #expect(abs(xs.min()! - (-r)) < 1e-6)
    #expect(abs(xs.max()! - (10 + r)) < 1e-6)
    #expect(abs(ys.min()! - (-r)) < 1e-6)
    #expect(abs(ys.max()! - r) < 1e-6)
}

@Test func widthFactors() {
    let low = pt(0, 0, 0), half = pt(0, 0, 0.5)
    #expect(abs(StrokeOutline.widthAt(low, baseWidth: 2, tool: .pen) - 0.4) < 1e-9)
    #expect(abs(StrokeOutline.widthAt(half, baseWidth: 2, tool: .pencil, gamma: 2) - 2 * (0.2 + 0.8 * 0.25)) < 1e-9)
    #expect(StrokeOutline.widthAt(low, baseWidth: 2, tool: .marker) == 2)
    #expect(StrokeOutline.widthAt(low, baseWidth: 2, tool: .highlighter) == 2)
}

@Test func curveSubdivisionKeepsSamplePoints() {
    let pts = [pt(0, 0), pt(5, 3), pt(10, 0), pt(15, 4)]
    let poly = StrokeOutline.polygon(pts, baseWidth: 1, tool: .marker)
    #expect(poly.count > 8 * 2)
    #expect(poly.allSatisfy { $0.x.isFinite && $0.y.isFinite })
}

@Test func emptyInputEmptyPolygon() {
    #expect(StrokeOutline.polygon([], baseWidth: 1, tool: .pen).isEmpty)
}
