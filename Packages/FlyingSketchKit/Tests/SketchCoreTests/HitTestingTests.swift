import Testing
@testable import SketchCore

private func pt(_ x: Double, _ y: Double) -> InkPoint { InkPoint(position: Vec2(x: x, y: y), pressure: 0.5, time: 0) }
private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

@Test func hitTestsStrokeNearLine() {
    let s = SceneObject.ink(InkStroke(points: [pt(0, 0), pt(10, 0)], baseWidth: 1))
    #expect(hitTest(s, point: v(5, 0.9), tolerance: 0.5))
    #expect(!hitTest(s, point: v(5, 3), tolerance: 0.5))
}

@Test func hitTestsDotStroke() {
    let dot = SceneObject.ink(InkStroke(points: [pt(2, 2)], baseWidth: 2))
    #expect(hitTest(dot, point: v(2.5, 2), tolerance: 0))
    #expect(!hitTest(dot, point: v(3.5, 2), tolerance: 0))
}

@Test func boundsOfInkIncludeWidth() {
    let s = SceneObject.ink(InkStroke(points: [pt(0, 0), pt(10, 4)], baseWidth: 2))
    let b = bounds(of: s)
    #expect(b == Rect(origin: v(-1, -1), size: v(12, 6)))
}

@Test func shapeOutlineVersusFill() {
    let hollow = SceneObject.shape(ShapeObject(kind: .rectangle, start: v(0, 0), end: v(10, 10), lineWidth: 1))
    let filled = SceneObject.shape(ShapeObject(kind: .rectangle, start: v(0, 0), end: v(10, 10), fillColor: .black, lineWidth: 1))
    #expect(!hitTest(hollow, point: v(5, 5), tolerance: 0.5))
    #expect(hitTest(hollow, point: v(0.3, 5), tolerance: 0.5))
    #expect(hitTest(filled, point: v(5, 5), tolerance: 0.5))
    #expect(!hitTest(filled, point: v(20, 5), tolerance: 0.5))
}

@Test func lineAndEllipseHits() {
    let line = SceneObject.shape(ShapeObject(kind: .line, start: v(0, 0), end: v(10, 0), lineWidth: 1))
    #expect(hitTest(line, point: v(5, 0.8), tolerance: 0.5))
    #expect(!hitTest(line, point: v(5, 2), tolerance: 0.5))
    let ell = SceneObject.shape(ShapeObject(kind: .ellipse, start: v(0, 0), end: v(10, 6), lineWidth: 0.2))
    #expect(hitTest(ell, point: v(5, 0), tolerance: 0.3))
    #expect(!hitTest(ell, point: v(5, 3), tolerance: 0.3))
}

@Test func textHitUsesRotatedFrame() {
    // frame 12 x 12 (fontSize 10, 2 chars -> 12 wide, 12 tall) at origin
    let t = SceneObject.text(TextObject(text: "ab", position: v(0, 0), fontSize: 10))
    #expect(hitTest(t, point: v(6, 6), tolerance: 0))
    #expect(!hitTest(t, point: v(20, 6), tolerance: 0))
    let r = SceneObject.text(TextObject(text: "abcdefghij", position: v(0, 0), fontSize: 10, rotation: .pi / 2))
    // rotated 90 deg around position: frame spans x in [-12,0], y in [0,60]
    #expect(hitTest(r, point: v(-6, 30), tolerance: 0))
    #expect(!hitTest(r, point: v(30, 6), tolerance: 0))
}

@Test func imageHitRotated() {
    let i = SceneObject.image(ImageObject(assetName: "a", frame: Rect(origin: v(0, 0), size: v(20, 2)), rotation: .pi / 2))
    // rotated around centre (10,1): becomes vertical strip x in [9,11], y in [-9,11]
    #expect(hitTest(i, point: v(10, -8), tolerance: 0))
    #expect(!hitTest(i, point: v(18, 1), tolerance: 0))
    let b = bounds(of: i)
    #expect(abs(b.minY + 9) < 1e-9 && abs(b.maxY - 11) < 1e-9)
}

@Test func lassoSelectsStrokeMostlyInside() {
    let square = [v(0, 0), v(10, 0), v(10, 10), v(0, 10)]
    func line(inside: Int, outside: Int) -> SceneObject {
        let pts = (0..<inside).map { _ in pt(5, 5) } + (0..<outside).map { _ in pt(50, 50) }
        return .ink(InkStroke(points: pts))
    }
    #expect(lassoContains(square, object: line(inside: 8, outside: 2)))
    #expect(!lassoContains(square, object: line(inside: 2, outside: 8)))
    let img = SceneObject.image(ImageObject(assetName: "a", frame: Rect(origin: v(2, 2), size: v(4, 4))))
    #expect(lassoContains(square, object: img))
    let far = SceneObject.image(ImageObject(assetName: "a", frame: Rect(origin: v(20, 20), size: v(4, 4))))
    #expect(!lassoContains(square, object: far))
}

@Test func multiLineTextBoundsAndHit() {
    let t = SceneObject.text(TextObject(text: "ab\nabcd\nx", position: .zero, fontSize: 10))
    let b = bounds(of: t)
    #expect(abs(b.size.x - 24) < 1e-9 && abs(b.size.y - 36) < 1e-9)
    #expect(hitTest(t, point: Vec2(x: 3, y: 30), tolerance: 0))
    #expect(!hitTest(t, point: Vec2(x: 3, y: 40), tolerance: 0))
}
