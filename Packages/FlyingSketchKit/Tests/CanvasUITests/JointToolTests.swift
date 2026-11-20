import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> SceneObject {
    .shape(ShapeObject(kind: .rectangle, start: v(x0, y0), end: v(x1, y1), fillColor: .black))
}

private func stroke(_ x: Double, _ y: Double) -> SceneObject {
    .ink(InkStroke(points: [
        InkPoint(position: v(x, y), pressure: 0.5, time: 0),
        InkPoint(position: v(x + 10, y), pressure: 0.5, time: 0.1),
    ], tool: .pen, baseWidth: 0.5))
}

@MainActor private func canvas(_ objects: [SceneObject], groups: [ObjectGroup] = []) -> (CanvasView, DocumentModel) {
    let m = DocumentModel(document: SketchDocument(objects: objects, groups: groups))
    let view = CanvasView(model: m)
    view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    view.layoutIfNeeded()
    view.toolState = ToolState(kind: .pin, pencilOnly: true)
    return (view, m)
}

@MainActor private func point(_ view: CanvasView, _ w: Vec2) -> CGPoint {
    let p = view.currentViewport.worldToView(w, viewSize: view.viewSize)
    return CGPoint(x: p.x, y: p.y)
}

/// Routes a Pencil touch at `w` and, when it is a pin tap, performs its release.
@MainActor private func tapPin(_ view: CanvasView, at w: Vec2) {
    guard case .pin(let start)? = view.route(isPencil: true, at: point(view, w)) else {
        Issue.record("expected .pin route"); return
    }
    view.pinTap(at: start)
}

@MainActor private func joints(_ m: DocumentModel) -> [Joint] {
    m.document.objects.compactMap { if case .joint(let j) = $0 { j } else { nil } }
}

@Test @MainActor func pinToolTapCreatesHinge() {
    let (view, m) = canvas([rect(0, 0, 40, 40), rect(20, 20, 60, 60)])
    tapPin(view, at: v(30, 30))
    let js = joints(m)
    #expect(js.count == 1)
    #expect(js[0].anchors.count == 2 && !js[0].grounded)
    #expect(m.undoManager.undoActionName == "Add Pin")
    m.undoManager.undo()
    #expect(joints(m).isEmpty)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func pinToolSingleBodyGrounds() {
    let (view, m) = canvas([rect(0, 0, 40, 40)])
    tapPin(view, at: v(10, 10))
    #expect(joints(m).count == 1 && joints(m)[0].grounded)
    #expect(m.undoManager.undoActionName == "Pin to Background")
    tapPin(view, at: v(300, 300)) // empty canvas
    #expect(joints(m).count == 1)
}

@Test @MainActor func pinToolTapOnPinTogglesGround() {
    let (view, m) = canvas([rect(0, 0, 40, 40), rect(20, 20, 60, 60)])
    tapPin(view, at: v(30, 30))
    tapPin(view, at: v(30, 30)) // lands on the pin, not on a third pin
    #expect(joints(m).count == 1 && joints(m)[0].grounded)
    #expect(m.undoManager.undoActionName == "Pin to Background")
    tapPin(view, at: v(30, 30))
    #expect(joints(m).count == 1 && !joints(m)[0].grounded)
    #expect(m.undoManager.undoActionName == "Release Pin")
}

@Test @MainActor func pinToolSnapsToGrid() {
    let (view, m) = canvas([rect(0, 0, 60, 60)])
    view.snapsToGrid = true
    tapPin(view, at: v(23, 38))
    #expect(joints(m).first?.position == v(20, 40))
    #expect(joints(m).first?.anchors.first?.point == v(20, 40))
}

@Test @MainActor func pinRoutingAndSlop() {
    let (view, _) = canvas([rect(0, 0, 40, 40)])
    let p = point(view, v(10, 10))
    guard case .pin(let start)? = view.route(isPencil: true, at: p) else { Issue.record("pencil"); return }
    #expect(start == p)
    // Finger with pencilOnly keeps selection behaviour.
    if case .pin? = view.route(isPencil: false, at: p) { Issue.record("finger must not pin") }
    view.toolState.pencilOnly = false
    guard case .pin? = view.route(isPencil: false, at: p) else { Issue.record("finger when !pencilOnly"); return }
    #expect(CanvasView.allowsUndoTap(during: .pin(start: p)))
}

@Test @MainActor func groupSelectsTogether() {
    let (view, m) = canvas([stroke(0, 0), stroke(0, 30)])
    view.selection.ids = Set(m.document.objects.map(\.id))
    view.groupSelection()
    #expect(m.document.groups.count == 1)
    #expect(m.undoManager.undoActionName == "Group")
    view.selection.ids = []
    view.toolState = ToolState(kind: .lasso, pencilOnly: true)
    view.tap(at: point(view, v(5, 0)))
    #expect(view.selection.ids == Set(m.document.objects.map(\.id)))
}

@Test @MainActor func lassoSelectsWholeGroup() {
    let (view, m) = canvas([stroke(0, 0), stroke(0, 200)])
    view.selection.ids = Set(m.document.objects.map(\.id))
    view.groupSelection()
    view.selection.ids = []
    view.lasso.begin(at: v(-5, -5))
    for p in [v(30, -5), v(30, 5), v(-5, 5)] { view.lasso.move(to: p) }
    view.finishLasso()
    #expect(view.selection.ids == Set(m.document.objects.map(\.id)))
}

@Test @MainActor func menuFlags() {
    let (a, b, c) = (stroke(0, 0), stroke(0, 30), stroke(0, 60))
    let (view, m) = canvas([a, b, c])
    view.selection.ids = [a.id, b.id]
    #expect(view.selectionCanGroup)
    #expect(!view.selectionCanUngroup)
    #expect(!view.selectionCanLock)
    view.groupSelection()
    #expect(view.selectionCanUngroup)
    #expect(view.selectionCanLock) // a whole group is one body
    #expect(!view.selectionCanGroup)
    view.selection.ids = [c.id]
    #expect(view.selectionCanLock && !view.selectionCanUngroup && !view.selectionCanGroup)
    view.selection.ids = []
    #expect(!view.selectionCanGroup && !view.selectionCanUngroup && !view.selectionCanLock)
    _ = m
}

@Test @MainActor func lockAndUnlockActions() {
    let (a, b) = (stroke(0, 0), stroke(0, 30))
    let (view, m) = canvas([a, b], groups: [ObjectGroup(members: [a.id, b.id])])
    view.selection.ids = [a.id, b.id]
    view.toggleLockSelection()
    #expect(joints(m).count == 1 && joints(m)[0].kind == .fixed)
    #expect(m.undoManager.undoActionName == "Lock in Place")
    #expect(view.selectionIsLocked)
    view.toggleLockSelection()
    #expect(joints(m).isEmpty)
    #expect(m.undoManager.undoActionName == "Unlock")
}

@Test @MainActor func ungroupIsOneUndoStep() {
    let (a, b) = (stroke(0, 0), stroke(0, 30))
    let (view, m) = canvas([a, b], groups: [ObjectGroup(members: [a.id, b.id])])
    view.selection.ids = [a.id]
    view.ungroupSelection()
    #expect(m.document.groups.isEmpty)
    #expect(m.undoManager.undoActionName == "Ungroup")
    m.undoManager.undo()
    #expect(m.document.groups.count == 1)
    #expect(!m.undoManager.canUndo)
}
