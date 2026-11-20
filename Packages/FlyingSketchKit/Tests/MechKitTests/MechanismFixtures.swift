import Foundation
import SketchCore

/// The four-bar of `SolverTests` as a document: ground hinges at A and D, `.line` bars crank AB, coupler BC and
/// rocker DC, hinges at B and C. AB = 10, BC = 35, DC = 25, AD = 40; C is the upper (y < 0) assembly.
struct FourBar {
    var doc: SketchDocument
    var a: Vec2, b: Vec2, c: Vec2, d: Vec2
    var crank: ObjectID, coupler: ObjectID, rocker: ObjectID
    var jointA: ObjectID, jointB: ObjectID, jointC: ObjectID, jointD: ObjectID
    var bars: [ObjectID] { [crank, coupler, rocker] }
    var joints: [ObjectID] { [jointA, jointB, jointC, jointD] }
}

func fourBarDocument() -> FourBar {
    let a = Vec2(x: 0, y: 0), d = Vec2(x: 40, y: 0), b = Vec2(x: 0, y: -10)
    let c = circleIntersections(b, 35, d, 25).min { $0.y < $1.y }!
    let crank = ShapeObject(kind: .line, start: a, end: b)
    let coupler = ShapeObject(kind: .line, start: b, end: c)
    let rocker = ShapeObject(kind: .line, start: d, end: c)
    let jA = Joint(position: a, anchors: [JointAnchor(object: crank.id, point: a)], grounded: true)
    let jD = Joint(position: d, anchors: [JointAnchor(object: rocker.id, point: d)], grounded: true)
    let jB = Joint(position: b, anchors: [JointAnchor(object: crank.id, point: b), JointAnchor(object: coupler.id, point: b)])
    let jC = Joint(position: c, anchors: [JointAnchor(object: coupler.id, point: c), JointAnchor(object: rocker.id, point: c)])
    let doc = SketchDocument(objects: [.shape(crank), .shape(coupler), .shape(rocker),
                                       .joint(jA), .joint(jB), .joint(jC), .joint(jD)])
    return FourBar(doc: doc, a: a, b: b, c: c, d: d, crank: crank.id, coupler: coupler.id, rocker: rocker.id,
                   jointA: jA.id, jointB: jB.id, jointC: jC.id, jointD: jD.id)
}

/// Crank tip B at `degrees` (y-down, clockwise positive; the start is -90°).
func crankTip(_ degrees: Double) -> Vec2 {
    let angle = degrees * .pi / 180
    return Vec2(x: 10 * cos(angle), y: 10 * sin(angle))
}

/// Intersection points of two circles (0, 1 or 2 points).
func circleIntersections(_ c1: Vec2, _ r1: Double, _ c2: Vec2, _ r2: Double) -> [Vec2] {
    let d = c1.distance(to: c2)
    guard d > 0, d <= r1 + r2, d >= abs(r1 - r2) else { return [] }
    let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
    let h = max(0, r1 * r1 - a * a).squareRoot()
    let u = (c2 - c1) / d
    let p = c1 + u * a
    let n = Vec2(x: -u.y, y: u.x)
    return h == 0 ? [p] : [p + n * h, p - n * h]
}

/// `doc` with `objects` replaced by id (the canvas applies drag results this way).
func applied(_ objects: [SceneObject], to doc: SketchDocument) -> SketchDocument {
    var out = doc
    _ = SceneEdit.replace(objects).apply(to: &out)
    return out
}
