import Testing
@testable import SketchCore

@Test func boundingOfPoints() {
    let r = Rect.bounding([Vec2(x: 0, y: 0), Vec2(x: 2, y: -1)])
    #expect(r == Rect(origin: Vec2(x: 0, y: -1), size: Vec2(x: 2, y: 1)))
}

@Test func boundingOfEmptyIsNil() {
    #expect(Rect.bounding([Vec2]()) == nil)
}

@Test func intersectsTouchingEdges() {
    let a = Rect(origin: .zero, size: Vec2(x: 1, y: 1))
    let b = Rect(origin: Vec2(x: 1, y: 0), size: Vec2(x: 1, y: 1))
    #expect(a.intersects(b))
    #expect(!a.intersects(Rect(origin: Vec2(x: 1.5, y: 0), size: Vec2(x: 1, y: 1))))
}

@Test func unionAndInset() {
    let a = Rect(origin: .zero, size: Vec2(x: 1, y: 1))
    let b = Rect(origin: Vec2(x: 2, y: 2), size: Vec2(x: 1, y: 1))
    #expect(a.union(b) == Rect(origin: .zero, size: Vec2(x: 3, y: 3)))
    #expect(a.insetBy(0.25) == Rect(origin: Vec2(x: 0.25, y: 0.25), size: Vec2(x: 0.5, y: 0.5)))
    #expect(a.contains(Vec2(x: 1, y: 1)) && !a.contains(Vec2(x: 1.1, y: 0)))
}

@Test func vecOps() {
    let v = Vec2(x: 3, y: 4)
    #expect(v.length == 5)
    #expect(abs(v.normalized.length - 1) < 1e-12)
    #expect(Vec2.zero.normalized == .zero)
    #expect(v + v == Vec2(x: 6, y: 8) && v - v == .zero && v * 2 == Vec2(x: 6, y: 8) && v / 2 == Vec2(x: 1.5, y: 2))
    let r = Vec2(x: 1, y: 0).rotated(by: .pi / 2)
    #expect(abs(r.x) < 1e-12 && abs(r.y - 1) < 1e-12)
}
