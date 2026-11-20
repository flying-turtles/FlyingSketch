import QuartzCore
import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private let viewSize = Vec2(x: 1024, y: 1366)
private let at = Vec2(x: 3, y: 4)

private func filledRect(_ center: Vec2) -> SceneObject {
    .shape(ShapeObject(kind: .rectangle, start: center - Vec2(x: 5, y: 5), end: center + Vec2(x: 5, y: 5),
                       strokeColor: .black, fillColor: .black, lineWidth: 0.5))
}

/// Object layers in sublayer order (root -> content -> [grid, objects]).
private func layers(_ root: CALayer) -> [CALayer] { root.sublayers![0].sublayers![1].sublayers ?? [] }

private func jointLayers(_ root: CALayer) -> [JointLayer] { layers(root).compactMap { $0 as? JointLayer } }

@MainActor private func settle(_ doc: SketchDocument, zoom: Double = 1) -> (SceneRenderer, CALayer) {
    let root = CALayer()
    let r = SceneRenderer(rootLayer: root)
    r.update(document: doc, viewport: Viewport(center: at, zoom: zoom), viewSize: viewSize, settled: true)
    return (r, root)
}

/// Union of every path the joint layer draws, in view points.
private func drawnBox(_ l: JointLayer) -> CGRect {
    (l.sublayers ?? []).compactMap { ($0 as? CAShapeLayer)?.path?.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
}

private func paths(_ l: JointLayer) -> [CGPath] { (l.sublayers ?? []).compactMap { ($0 as? CAShapeLayer)?.path } }

@Test @MainActor func jointLayerAboveLaterObjects() {
    let joint = Joint(position: at)
    let shape = filledRect(at)
    let (_, root) = settle(SketchDocument(objects: [.joint(joint), shape]))
    let all = layers(root)
    let jl = all.first { $0 is JointLayer }!
    let other = all.first { !($0 is JointLayer) }!
    #expect(jl.zPosition > other.zPosition)
}

@Test @MainActor func jointStaysAboveInMovePreview() {
    let joint = Joint(position: at)
    let shape = filledRect(at)
    let doc = SketchDocument(objects: [.joint(joint), shape])
    let (r, root) = settle(doc)
    var moved = joint
    moved.position = at + Vec2(x: 2, y: 0)
    var movedShape = shape
    if case .shape(var s) = shape { s.start = s.start + Vec2(x: 1, y: 0); movedShape = .shape(s) }
    r.setMovePreview(ids: [], offset: .zero, replacing: [.joint(moved), movedShape])
    let all = layers(root)
    #expect(all.first { $0 is JointLayer }!.zPosition > all.first { !($0 is JointLayer) }!.zPosition)
    r.setMovePreview(ids: [], offset: .zero)
    #expect(layers(root).first { $0 is JointLayer }!.zPosition > layers(root).first { !($0 is JointLayer) }!.zPosition)
}

@Test @MainActor func jointLayerIsUpdatedNotRecreated() {
    let joint = Joint(position: at)
    let (r, root) = settle(SketchDocument(objects: [.joint(joint)]))
    let first = jointLayers(root).first!
    var moved = joint
    moved.position = at + Vec2(x: 5, y: 0)
    r.update(document: SketchDocument(objects: [.joint(moved)]), viewport: Viewport(center: at, zoom: 1),
             viewSize: viewSize, settled: true)
    #expect(jointLayers(root).first === first)
    #expect(drawnBox(first).midX > 0)
}

@Test @MainActor func groundedAndFixedMarksDiffer() {
    func drawn(_ j: Joint) -> JointLayer {
        let (_, root) = settle(SketchDocument(objects: [.joint(j)]))
        return jointLayers(root).first!
    }
    let plain = drawn(Joint(position: at))
    let grounded = drawn(Joint(position: at, grounded: true))
    let fixed = drawn(Joint(kind: .fixed, position: at, grounded: true))
    let sets = [plain, grounded, fixed].map { l in paths(l).map(\.boundingBoxOfPath) }
    #expect(sets[0] != sets[1] && sets[0] != sets[2] && sets[1] != sets[2])
    // Plain hinge: ring 2.4 mm wide plus one stroke.
    let ppm = Viewport.pointsPerMillimetre
    let ringWidth = paths(plain).map(\.boundingBoxOfPath).map(\.width).max() ?? 0
    #expect(abs(ringWidth - 2.4 * ppm) <= JointGeometry.strokeWidth * ppm)
    // Grounded reaches lower than the plain hinge; the lock has no ring.
    #expect(drawnBox(grounded).maxY > drawnBox(plain).maxY)
    #expect(paths(fixed).allSatisfy { $0.boundingBoxOfPath.width < 2.4 * ppm + 1 })
}

@Test @MainActor func jointSizeScalesWithZoom() {
    func width(_ zoom: Double) -> CGFloat {
        let (_, root) = settle(SketchDocument(objects: [.joint(Joint(position: at))]), zoom: zoom)
        return drawnBox(jointLayers(root).first!).width
    }
    #expect(abs(width(2) / width(1) - 2) < 0.05)
}

@Test @MainActor func topObjectPrefersJoint() {
    let m = DocumentModel(document: SketchDocument(objects: [.joint(Joint(position: .zero)), filledRect(.zero)]))
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    // Default viewport centres world origin in the view.
    let hit = v.topObject(at: CGPoint(x: 512, y: 683))
    guard case .joint = hit else { Issue.record("expected joint, got \(String(describing: hit))"); return }
}
