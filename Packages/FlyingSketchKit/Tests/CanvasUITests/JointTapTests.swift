import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

private func plate(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> ShapeObject {
    ShapeObject(kind: .rectangle, start: v(x0, y0), end: v(x1, y1), fillColor: .black)
}

/// Finger-selection canvas (pencilOnly) at `zoom`, centred on the origin.
@MainActor private func canvas(_ objects: [SceneObject], groups: [ObjectGroup] = [], zoom: Double = 4)
    -> (CanvasView, DocumentModel) {
    let m = DocumentModel(document: SketchDocument(objects: objects, groups: groups))
    let view = CanvasView(model: m)
    view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    view.layoutIfNeeded()
    view.viewport = Viewport(center: v(0, 0), zoom: zoom)
    view.toolState = ToolState(kind: .lasso, pencilOnly: true)
    return (view, m)
}

@MainActor private func point(_ view: CanvasView, _ w: Vec2) -> CGPoint {
    let p = view.currentViewport.worldToView(w, viewSize: view.viewSize)
    return CGPoint(x: p.x, y: p.y)
}

/// Finger tap through the real touch handlers.
@MainActor private func fingerTap(_ view: CanvasView, at w: Vec2) {
    view.drive(FakeTouch(at: point(view, w), type: .direct), from: point(view, w))
}

// MARK: Lock marks never win a tap (item 1)

@Test @MainActor func tapOnLockSelectsLockedBody() {
    let body = plate(-10, -10, 10, 10)
    let lock = Joint(kind: .fixed, position: v(0, 0), anchors: [JointAnchor(object: body.id, point: v(0, 0))],
                     grounded: true)
    let (view, _) = canvas([.shape(body), .joint(lock)])
    fingerTap(view, at: v(0, 0))
    #expect(view.selection.ids == [body.id])
    // A second tap (now inside the selection) keeps the body selected (edit menu), not the lock.
    fingerTap(view, at: v(0, 0))
    #expect(view.selection.ids == [body.id])
}

@Test @MainActor func tapOnLockOfGroupSelectsWholeGroup() {
    let a = plate(-10, -10, 10, 10), b = plate(30, 0, 40, 10)
    let lock = Joint(kind: .fixed, position: v(0, 0), anchors: [JointAnchor(object: a.id, point: v(0, 0))],
                     grounded: true)
    let (view, _) = canvas([.shape(a), .shape(b), .joint(lock)], groups: [ObjectGroup(members: [a.id, b.id])])
    fingerTap(view, at: v(0, 0))
    #expect(view.selection.ids == [a.id, b.id])
}

/// The lock of a U-shaped stroke sits at its bounds centre, off the ink: a tap there still selects the stroke.
@Test @MainActor func tapOnLockOffTheInkSelectsBody() {
    let u = InkStroke(points: [v(-10, -10), v(-10, 10), v(10, 10), v(10, -10)].enumerated().map {
        InkPoint(position: $0.element, pressure: 0.5, time: Double($0.offset) * 0.1)
    }, tool: .pen, baseWidth: 0.5)
    let lock = Joint(kind: .fixed, position: v(0, 0), anchors: [JointAnchor(object: u.id, point: v(0, 0))],
                     grounded: true)
    let (view, _) = canvas([.ink(u), .joint(lock)])
    fingerTap(view, at: v(0, 0))
    #expect(view.selection.ids == [u.id])
}

@Test @MainActor func hingeStillWinsTapOverBody() {
    let a = plate(-10, -10, 10, 10), b = plate(0, 0, 20, 20)
    let hinge = Joint(position: v(5, 5), anchors: [JointAnchor(object: a.id, point: v(5, 5)),
                                                   JointAnchor(object: b.id, point: v(5, 5))])
    let (view, _) = canvas([.shape(a), .shape(b), .joint(hinge)])
    fingerTap(view, at: v(5, 5))
    #expect(view.selection.ids == [hinge.id])
}

// MARK: Ground mark is part of the hinge's target (item 2)

@Test @MainActor func tapOnGroundMarkSelectsHinge() {
    let body = plate(-10, -10, 10, 10)
    let ground = Joint(position: v(0, 0), anchors: [JointAnchor(object: body.id, point: v(0, 0))], grounded: true)
    let (view, _) = canvas([.shape(body), .joint(ground)])
    // Right end of the ground mark's base line (1.8 mm below, 1.8 mm right): outside the ring and its slop at zoom 4.
    let onMark = v(JointGeometry.groundHalfWidth, JointGeometry.groundDrop + 0.1)
    #expect(onMark.length > Joint.radius + Double(CanvasView.hitSlop) / (Viewport.pointsPerMillimetre * 4))
    fingerTap(view, at: onMark)
    #expect(view.selection.ids == [ground.id])
    // Well below the mark: the plate.
    fingerTap(view, at: v(0, 6))
    #expect(view.selection.ids == [body.id])
}

@Test @MainActor func ungroundedHingeHasNoMarkTarget() {
    let a = plate(-10, -10, 10, 10), b = plate(-5, -5, 5, 5)
    let hinge = Joint(position: v(0, 0), anchors: [JointAnchor(object: a.id, point: v(0, 0)),
                                                   JointAnchor(object: b.id, point: v(0, 0))])
    let (view, _) = canvas([.shape(a), .shape(b), .joint(hinge)])
    fingerTap(view, at: v(JointGeometry.groundHalfWidth, JointGeometry.groundDrop + 0.1))
    #expect(view.selection.ids == [b.id])
}

@Test @MainActor func pinToolTapOnGroundMarkKeepsPin() {
    let body = plate(-10, -10, 10, 10)
    let ground = Joint(position: v(0, 0), anchors: [JointAnchor(object: body.id, point: v(0, 0))], grounded: true)
    let (view, m) = canvas([.shape(body), .joint(ground)])
    // On the mark, outside the ring: a second pin at the tap, the first one stays grounded.
    view.pinTap(at: point(view, v(JointGeometry.groundHalfWidth, JointGeometry.groundDrop + 0.1)))
    let joints = m.document.objects.compactMap { if case .joint(let j) = $0 { j } else { nil } }
    #expect(joints.count == 2 && joints.allSatisfy(\.grounded))
    #expect(joints.contains { $0.id == ground.id })
}
