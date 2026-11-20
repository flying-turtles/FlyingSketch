import Foundation
import Testing
@testable import SketchCore

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

private func rect(rotation: Double, filled: Bool = false, kind: ShapeKind = .rectangle) -> SceneObject {
    .shape(ShapeObject(kind: kind, start: v(0, 0), end: v(20, 10), fillColor: filled ? .black : nil,
                       lineWidth: 0, rotation: rotation))
}

private func wrapper(_ json: String) -> FileWrapper {
    FileWrapper(directoryWithFileWrappers: ["document.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
}

@Test func shapeDecodesWithoutRotation() throws {
    let s = ShapeObject(kind: .rectangle, start: v(0, 0), end: v(2, 2), rotation: 1)
    var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
    #expect(obj["rotation"] != nil)
    obj.removeValue(forKey: "rotation")
    let decoded = try JSONDecoder().decode(ShapeObject.self, from: JSONSerialization.data(withJSONObject: obj))
    #expect(decoded.rotation == 0)
}

@Test func rotatedRectBounds() {
    let b = bounds(of: rect(rotation: .pi / 2))
    #expect(abs(b.minX - 5) < 1e-9 && abs(b.minY + 5) < 1e-9)
    #expect(abs(b.size.x - 10) < 1e-9 && abs(b.size.y - 20) < 1e-9)
}

@Test func rotatedRectHitTest() {
    let o = rect(rotation: .pi / 2)
    #expect(hitTest(o, point: v(5, 0), tolerance: 0.5))
    #expect(!hitTest(o, point: v(0, 5), tolerance: 0.5))
    #expect(hitTest(rect(rotation: .pi / 2, filled: true), point: v(10, -4), tolerance: 0.5))
}

@Test func rotatedEllipseHitTest() {
    let o = rect(rotation: .pi / 2, filled: true, kind: .ellipse)
    #expect(hitTest(o, point: v(10, -4), tolerance: 0.5))
    #expect(!hitTest(o, point: v(1, 5), tolerance: 0.5))
}

@Test func lineIgnoresRotationField() {
    func line(_ r: Double) -> SceneObject {
        .shape(ShapeObject(kind: .line, start: v(0, 0), end: v(20, 10), lineWidth: 1, rotation: r))
    }
    #expect(bounds(of: line(1)) == bounds(of: line(0)))
    for p in [v(10, 5), v(10, 0), v(0, 10), v(20, 10)] {
        #expect(hitTest(line(1), point: p, tolerance: 0.5) == hitTest(line(0), point: p, tolerance: 0.5))
    }
}

@Test func cornersFollowRotation() {
    guard case .shape(let s) = rect(rotation: .pi / 2) else { return }
    #expect(ShapeGeometry.center(of: s) == v(10, 5))
    let expected = [v(15, -5), v(15, 15), v(5, 15), v(5, -5)]
    for (c, e) in zip(ShapeGeometry.corners(of: s), expected) { #expect(c.distance(to: e) < 1e-9) }
}

@Test func nonFiniteShapeRotationRejected() throws {
    let s = ShapeObject(kind: .rectangle, start: v(0, 0), end: v(2, 2), rotation: 0.5)
    let doc = SketchDocument(objects: [.shape(s)])
    let w = try DocumentPackage.fileWrapper(for: doc)
    let data = try #require(w.fileWrappers?["document.json"]?.regularFileContents)
    var json = String(decoding: data, as: UTF8.self)
    let range = try #require(json.range(of: "\"rotation\":0.5"))
    json.replaceSubrange(range, with: "\"rotation\":1e999")
    do {
        _ = try DocumentPackage.read(wrapper(json))
        Issue.record("expected throw")
    } catch let e as DocumentError {
        guard case .corrupt = e else { Issue.record("expected .corrupt, got \(e)"); return }
    }
}
