import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }
private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { a.distance(to: b) <= tol }

private let stroke = InkStroke(points: [
    InkPoint(position: Vec2(x: 0, y: 0), pressure: 0.5, time: 0),
    InkPoint(position: Vec2(x: 20, y: 0), pressure: 0.5, time: 0.1),
], tool: .pen, baseWidth: 0.5)

@MainActor private func canvas(_ objects: [SceneObject] = [.ink(stroke)], parts: [String: PartDefinition] = [:],
                               select: Bool = true) -> (CanvasView, DocumentModel) {
    let m = DocumentModel(document: SketchDocument(objects: objects, parts: parts))
    let view = CanvasView(model: m)
    view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    view.layoutIfNeeded()
    view.toolState = ToolState(kind: .lasso, pencilOnly: true)
    if select { view.selection.ids = Set(objects.map(\.id)) }
    return (view, m)
}

@MainActor private func point(_ view: CanvasView, _ w: Vec2) -> CGPoint {
    let p = view.currentViewport.worldToView(w, viewSize: view.viewSize)
    return CGPoint(x: p.x, y: p.y)
}

@MainActor private func world(_ view: CanvasView, _ p: CGPoint) -> Vec2 { view.worldPoint(p) }

@MainActor private func docStroke(_ m: DocumentModel) -> InkStroke {
    for case .ink(let s) in m.document.objects { return s }
    fatalError()
}

@MainActor private func controller() -> (DocumentModel, RotationController) {
    let m = DocumentModel(document: SketchDocument(objects: [.ink(stroke)]))
    let c = RotationController(model: m)
    c.minDistance = 0.5
    return (m, c)
}

// MARK: Controller

@Test @MainActor func rotatesByDragAngle() {
    let (m, c) = controller()
    c.begin(ids: [stroke.id], pivot: .zero, grabAt: v(10, 0))
    #expect(!c.move(to: v(0, 10)).isEmpty)
    #expect(c.end(at: v(0, 10)))
    #expect(near(docStroke(m).points[1].position, v(0, 20)))
    #expect(m.undoManager.undoActionName == "Rotate")
    m.undoManager.undo()
    #expect(near(docStroke(m).points[1].position, v(20, 0)))
}

@Test @MainActor func snapsTo15Degrees() {
    let (_, c) = controller()
    c.snapsAngle = true
    c.begin(ids: [stroke.id], pivot: .zero, grabAt: v(10, 0))
    let a = 20 * Double.pi / 180
    _ = c.move(to: v(10 * cos(a), 10 * sin(a)))
    #expect(abs(c.angle - .pi / 12) < 1e-12)
}

@Test @MainActor func tapMakesNoEdit() {
    let (m, c) = controller()
    c.begin(ids: [stroke.id], pivot: .zero, grabAt: v(10, 0))
    #expect(!c.end(at: v(10, 0.2)))
    #expect(!m.undoManager.canUndo)
    #expect(!c.isActive)
}

@Test @MainActor func dragAwayAndBackToZeroNoEdit() {
    let (m, c) = controller()
    c.begin(ids: [stroke.id], pivot: .zero, grabAt: v(10, 0))
    _ = c.move(to: v(0, 10))
    #expect(!c.end(at: v(30, 0))) // back on the grab ray: angle 0
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func rotateCancelNoEdit() {
    let (m, c) = controller()
    c.begin(ids: [stroke.id], pivot: .zero, grabAt: v(10, 0))
    _ = c.move(to: v(0, 10))
    c.cancel()
    #expect(!c.isActive && c.angle == 0)
    #expect(c.move(to: v(0, 10)).isEmpty)
    #expect(!c.end(at: v(0, 10)))
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func documentChangeCancels() {
    let (m, c) = controller()
    c.begin(ids: [stroke.id], pivot: .zero, grabAt: v(10, 0))
    var other = SceneObject.shape(ShapeObject(kind: .line, start: .zero, end: v(5, 5)))
    m.perform(.insert([other], at: nil), actionName: "Add")
    #expect(!c.documentDidChange(m.document)) // unrelated object: keeps going
    #expect(c.isActive)
    var moved = stroke
    moved.baseWidth = 2
    other = .ink(moved)
    m.perform(.replace([other]), actionName: "Widen")
    #expect(c.documentDidChange(m.document))
    #expect(!c.isActive)
}

// MARK: Canvas

@Test @MainActor func handleShownAboveSelection() {
    let (view, _) = canvas()
    view.updateSelectionOverlay() // the selection observer runs asynchronously
    guard let c = view.rotateHandleCenter, let r = view.selectionViewRect else { Issue.record("no handle"); return }
    #expect(abs(c.x - r.midX) < 1e-6 && abs(c.y - (r.minY - 28)) < 1e-6)
    #expect(!view.rotateHandle.isHidden)
    view.selection.ids = []
    view.updateSelectionOverlay()
    #expect(view.rotateHandleCenter == nil)
    #expect(view.rotateHandle.isHidden)
}

@Test @MainActor func routeHitsRotateHandle() throws {
    let (view, _) = canvas()
    let c = try #require(view.rotateHandleCenter)
    guard case .rotate? = view.route(isPencil: true, at: c) else { Issue.record("expected rotate"); return }
    guard case .rotate? = view.route(isPencil: true, at: CGPoint(x: c.x + 15, y: c.y)) else { Issue.record("hit radius"); return }
    if case .rotate? = view.route(isPencil: true, at: CGPoint(x: c.x + 17, y: c.y)) { Issue.record("outside hit radius") }
    view.toolState = ToolState(kind: .wire, pencilOnly: true)
    if case .rotate? = view.route(isPencil: true, at: c) { Issue.record("wire tool rotated") }
    // Finger in Pencil-only mode selects, so it may rotate.
    guard case .rotate? = view.route(isPencil: false, at: c) else { Issue.record("finger should rotate"); return }
}

@Test @MainActor func rotateDragEndToEnd() throws {
    let (view, m) = canvas()
    let handle = try #require(view.rotateHandleCenter)
    let b = try #require(view.selectionWorldBounds)
    let pivot = v((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2)
    let grab = world(view, handle)
    view.beginRotate(at: grab)
    view.moveRotate(to: pivot + (grab - pivot).rotated(by: .pi / 2))
    #expect(!view.rotatePreview.isEmpty)
    #expect(view.rotateHandleCenter == nil)
    #expect(view.selectionOverlay.layer.isHidden)
    #expect(view.rotateHandle.isHidden)
    view.endRotate(at: pivot + (grab - pivot).rotated(by: .pi / 2))
    let s = docStroke(m)
    #expect(near(s.points[0].position, pivot + (v(0, 0) - pivot).rotated(by: .pi / 2)))
    #expect(near(s.points[1].position, pivot + (v(20, 0) - pivot).rotated(by: .pi / 2)))
    #expect(view.rotatePreview.isEmpty)
    #expect(view.rotateHandleCenter != nil)
    #expect(!view.rotateHandle.isHidden && !view.selectionOverlay.layer.isHidden)
    #expect(m.undoManager.undoActionName == "Rotate")
}

@Test @MainActor func cancelRestoresHandlesAndDoc() throws {
    let (view, m) = canvas()
    let grab = world(view, try #require(view.rotateHandleCenter))
    view.interaction = .rotate
    view.beginRotate(at: grab)
    view.moveRotate(to: grab + v(30, 30))
    view.cancelInteraction()
    #expect(view.rotatePreview.isEmpty && !view.rotator.isActive)
    #expect(view.rotateHandleCenter != nil && !view.selectionOverlay.layer.isHidden)
    #expect(!m.undoManager.canUndo)
    #expect(near(docStroke(m).points[1].position, v(20, 0)))
}

@Test @MainActor func rotatePartCarriesPluggedAndWires() throws {
    let boardDef = PartDefinition.fixtureBreadboardMini()
    let moduleDef = PartDefinition.fixtureModule()
    let board = PartInstance(definitionKey: boardDef.key, center: v(40, 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: v(40, 0))
    module.center = module.center + (connectorPositions(board, boardDef)["c0r1"]! - connectorPositions(module, moduleDef)["VCC"]!)
    let pin = connectorPositions(module, moduleDef)["GND"]!
    let wire = Wire(start: WireEnd(position: pin, attachment: .connector(part: module.id, connector: "GND")),
                    end: WireEnd(position: v(60, 30)))
    let (view, m) = canvas([.part(board), .part(module), .wire(wire)],
                           parts: [boardDef.key: boardDef, moduleDef.key: moduleDef], select: false)
    view.selection.ids = [board.id]
    let before = contacts(in: m.document)
    #expect(!before.isEmpty)
    let handle = try #require(view.rotateHandleCenter)
    let b = try #require(view.selectionWorldBounds)
    let pivot = v((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2)
    let grab = world(view, handle)
    view.beginRotate(at: grab)
    let target = pivot + (grab - pivot).rotated(by: .pi / 2)
    view.moveRotate(to: target)
    view.endRotate(at: target)
    #expect(contacts(in: m.document) == before)
    var parts: [ObjectID: PartInstance] = [:]
    var wireAfter: Wire?
    for o in m.document.objects {
        if case .part(let p) = o { parts[p.id] = p }
        if case .wire(let w) = o { wireAfter = w }
    }
    #expect(abs(normalizedAngle(parts[board.id]!.rotation) - .pi / 2) < 1e-9)
    #expect(abs(normalizedAngle(parts[module.id]!.rotation) - .pi / 2) < 1e-9)
    let m2 = try #require(parts[module.id])
    #expect(near(try #require(wireAfter).start.position, connectorPositions(m2, moduleDef)["GND"]!))
}

@Test @MainActor func outsideUndoCancelsRotate() throws {
    let (view, m) = canvas()
    var other = stroke
    other.baseWidth = 2
    m.perform(.replace([.ink(other)]), actionName: "Widen")
    let grab = world(view, try #require(view.rotateHandleCenter))
    view.interaction = .rotate
    view.beginRotate(at: grab)
    view.moveRotate(to: grab + v(30, 30))
    m.undoManager.undo() // e.g. toolbar Undo while the Pencil drags
    #expect(!view.rotator.isActive)
    #expect(view.rotatePreview.isEmpty)
}

@Test @MainActor func undoTapBlockedDuringRotate() {
    #expect(!CanvasView.allowsUndoTap(during: .rotate))
}

// MARK: Review fixes

private func rect(rotation: Double) -> ShapeObject {
    ShapeObject(kind: .rectangle, start: v(5, 5), end: v(15, 10), rotation: rotation)
}

@MainActor private func docShape(_ m: DocumentModel, _ id: ObjectID) -> ShapeObject {
    for case .shape(let s) in m.document.objects where s.id == id { return s }
    fatalError()
}

@MainActor private func dragged(_ objects: [SceneObject], degrees: Double) -> (DocumentModel, RotationController) {
    let m = DocumentModel(document: SketchDocument(objects: objects))
    let c = RotationController(model: m)
    c.minDistance = 0.5
    c.snapsAngle = true
    c.begin(ids: Set(objects.map(\.id)), pivot: .zero, grabAt: v(10, 0))
    let a = degrees * Double.pi / 180
    let to = v(10 * cos(a), 10 * sin(a))
    _ = c.move(to: to)
    c.end(at: to)
    return (m, c)
}

@Test @MainActor func singleRotatedShapeSnapsResultingRotation() {
    let r = rect(rotation: 0.24)
    let (m, _) = dragged([.shape(r)], degrees: 20)
    let rot = docShape(m, r.id).rotation
    let step = Double.pi / 12
    #expect(abs(rot / step - (rot / step).rounded()) < 1e-9)
    #expect(abs(rot - .pi / 6) < 1e-9)
}

@Test @MainActor func singleRotatedShapeSnapsBackToStraight() {
    let r = rect(rotation: 0.24)
    let (m, _) = dragged([.shape(r)], degrees: -13)
    #expect(abs(normalizedAngle(docShape(m, r.id).rotation)) < 1e-9)
}

@Test @MainActor func singleObjectAngleReportsEffectiveDelta() {
    let r = rect(rotation: 0.24)
    let (_, c) = dragged([.shape(r)], degrees: 20)
    _ = c // controller reset by end; check mid-drag instead
    let m = DocumentModel(document: SketchDocument(objects: [.shape(r)]))
    let k = RotationController(model: m)
    k.snapsAngle = true
    k.begin(ids: [r.id], pivot: .zero, grabAt: v(10, 0))
    let a = 20 * Double.pi / 180
    _ = k.move(to: v(10 * cos(a), 10 * sin(a)))
    #expect(abs(k.angle - (.pi / 6 - 0.24)) < 1e-9)
}

@Test @MainActor func twoObjectSelectionStillSnapsDelta() {
    let r = rect(rotation: 0.24)
    let r2 = ShapeObject(kind: .rectangle, start: v(20, 5), end: v(30, 10))
    let m = DocumentModel(document: SketchDocument(objects: [.shape(r), .shape(r2)]))
    let k = RotationController(model: m)
    k.snapsAngle = true
    k.begin(ids: [r.id, r2.id], pivot: .zero, grabAt: v(10, 0))
    let a = 20 * Double.pi / 180
    _ = k.move(to: v(10 * cos(a), 10 * sin(a)))
    #expect(abs(k.angle - .pi / 12) < 1e-12)
}

@Test @MainActor func editMenuTargetRectClearsRotateKnob() throws {
    let (view, _) = canvas()
    let r = try #require(view.selectionViewRect)
    let target = view.editMenuInteraction(UIEditMenuInteraction(delegate: nil),
                                          targetRectFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero))
    #expect(abs(target.minY - (r.minY - 44)) < 1e-6)
    #expect(abs(target.maxY - r.maxY) < 1e-6)
    #expect(abs(target.minX - r.minX) < 1e-6 && abs(target.maxX - r.maxX) < 1e-6)
}
