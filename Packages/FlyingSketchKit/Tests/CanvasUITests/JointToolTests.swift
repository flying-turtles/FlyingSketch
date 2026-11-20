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

@Test @MainActor func snappedTapNearPinTogglesInsteadOfDuplicating() {
    let (view, m) = canvas([rect(0, 0, 60, 60), rect(10, 10, 70, 70)])
    view.snapsToGrid = true
    tapPin(view, at: v(23, 38))
    #expect(joints(m).first?.position == v(20, 40))
    tapPin(view, at: v(24, 37)) // misses the pin raw, snaps onto it: must toggle
    #expect(joints(m).count == 1 && joints(m)[0].grounded)
}

@Test @MainActor func ungroupKeepsLockOnCanvas() {
    let (a, b) = (stroke(0, 0), stroke(0, 100))
    let (view, m) = canvas([a, b], groups: [ObjectGroup(members: [a.id, b.id])])
    view.selection.ids = [a.id]
    view.toggleLockSelection()
    view.ungroupSelection()
    #expect(m.document.groups.isEmpty)
    #expect(joints(m).count == 1 && joints(m)[0].kind == .fixed)
}

@Test @MainActor func ungroupIgnoresZoom() {
    func run(zoom: Double) -> Bool {
        let a = rect(0, 0, 40, 10), b = rect(50, 0, 90, 10), c = rect(0, 30, 120, 40)
        let hinge = Joint(position: v(91, 5), anchors: [JointAnchor(object: a.id, point: v(91, 5)),
                                                        JointAnchor(object: c.id, point: v(91, 5))])
        let (view, m) = canvas([a, b, c, .joint(hinge)], groups: [ObjectGroup(members: [a.id, b.id])])
        view.viewport = Viewport(center: v(91, 5), zoom: zoom)
        view.layoutIfNeeded()
        view.selection.ids = [a.id]
        view.ungroupSelection()
        return joints(m).first?.anchors.first?.object == b.id
    }
    #expect(run(zoom: 0.25))
    #expect(run(zoom: 4))
}

@Test @MainActor func groupDropsStaleHingeFromSelection() {
    let (a, b) = (rect(0, 0, 40, 10), rect(30, 0, 70, 10))
    let hinge = Joint(position: v(35, 5), anchors: [JointAnchor(object: a.id, point: v(35, 5)),
                                                    JointAnchor(object: b.id, point: v(35, 5))])
    let (view, m) = canvas([a, b, .joint(hinge)])
    view.selection.ids = [a.id, b.id, hinge.id]
    view.groupSelection()
    #expect(view.selection.ids == [a.id, b.id])
    m.undoManager.undo()
    #expect(m.document.groups.isEmpty && joints(m).count == 1)
}

@Test @MainActor func pinTouchPathTapAndSlop() {
    // UITouch cannot be faked here: exercise the release path via the interaction value instead.
    let (view, m) = canvas([rect(0, 0, 40, 40)])
    view.interaction = .pin(start: point(view, v(10, 10)))
    if case .pin(let s)? = view.interaction { view.pinTap(at: s) }
    #expect(joints(m).count == 1)
}

@Test @MainActor func tapOnPivotAddsThirdBar() {
    let (a, b, c) = (rect(0, 0, 40, 40), rect(20, 20, 60, 60), rect(25, 25, 35, 35))
    let pivot = v(30, 30)
    let hinge = Joint(position: pivot, anchors: [JointAnchor(object: a.id, point: pivot), JointAnchor(object: b.id, point: pivot)])
    let (view, m) = canvas([a, b, .joint(hinge), c])
    tapPin(view, at: pivot)
    #expect(joints(m).count == 1)
    #expect(joints(m).first?.id == hinge.id)
    #expect(joints(m).first.map { Set($0.anchors.map(\.object)) } == [a.id, b.id, c.id])
    #expect(joints(m).first?.grounded == false)
    #expect(m.undoManager.undoActionName == "Add Pin")
    m.undoManager.undo()
    #expect(joints(m) == [hinge])
    #expect(!m.undoManager.canUndo)
    m.undoManager.redo()
    #expect(joints(m).first?.anchors.count == 3)
    tapPin(view, at: pivot) // every body under the pivot is held now: toggles ground
    #expect(joints(m).count == 1 && joints(m)[0].grounded && joints(m)[0].anchors.count == 3)
}

@Test @MainActor func tapOnLockMarkPinsUnderneath() {
    let (plate, other) = (rect(0, 0, 40, 40), rect(10, 10, 30, 30))
    let centre = v(20, 20)
    let lock = Joint(kind: .fixed, position: centre, anchors: [JointAnchor(object: plate.id, point: centre)], grounded: true)
    let (view, m) = canvas([plate, .joint(lock), other])
    tapPin(view, at: centre)
    let js = joints(m)
    #expect(js.count == 2)
    #expect(js.contains(lock))
    let hinge = js.first { $0.kind == .hinge }
    #expect(hinge?.position == centre)
    #expect(hinge.map { Set($0.anchors.map(\.object)) } == [plate.id, other.id])
    #expect(hinge?.grounded == false)
}
