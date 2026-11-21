import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }
private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-6) -> Bool { a.distance(to: b) <= tol }

private let looseStroke = InkStroke(points: [
    InkPoint(position: v(0, 30), pressure: 0.5, time: 0),
    InkPoint(position: v(20, 30), pressure: 0.5, time: 0.1),
], tool: .pen, baseWidth: 0.5)

@MainActor private func canvas(_ doc: SketchDocument, select: Set<ObjectID>) -> (CanvasView, DocumentModel) {
    let m = DocumentModel(document: doc)
    let view = CanvasView(model: m)
    view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    view.layoutIfNeeded()
    view.toolState = ToolState(kind: .lasso, pencilOnly: true)
    view.selection.ids = select
    view.updateSelectionOverlay() // the selection observer runs asynchronously
    return (view, m)
}

@MainActor private func point(_ view: CanvasView, _ w: Vec2) -> CGPoint {
    let p = view.currentViewport.worldToView(w, viewSize: view.viewSize)
    return CGPoint(x: p.x, y: p.y)
}

private func object(_ id: ObjectID, in doc: SketchDocument) -> SceneObject? { doc.objects.first { $0.id == id } }

private func shape(_ id: ObjectID, in doc: SketchDocument) -> ShapeObject {
    guard case .shape(let s)? = object(id, in: doc) else { fatalError("no shape \(id)") }
    return s
}

private func joint(_ id: ObjectID, in doc: SketchDocument) -> Joint {
    guard case .joint(let j)? = object(id, in: doc) else { fatalError("no joint \(id)") }
    return j
}

private func length(_ s: ShapeObject) -> Double { s.start.distance(to: s.end) }

/// Every hinge's anchors coincide (grounded: on `position`).
private func expectPinsHold(_ doc: SketchDocument, _ label: String = "") {
    for case .joint(let j) in doc.objects {
        let first = j.anchors[0].point
        for anchor in j.anchors { #expect(near(anchor.point, first), "\(label) anchors apart") }
        if j.grounded { #expect(near(first, j.position), "\(label) off ground") }
    }
}

private func expectLengths(_ doc: SketchDocument, _ ids: [ObjectID], like start: SketchDocument) {
    for id in ids { #expect(abs(length(shape(id, in: doc)) - length(shape(id, in: start))) < 1e-9, "bar length") }
}

private func isMechanism(_ i: CanvasView.Interaction?, _ id: ObjectID) -> Bool {
    if case .mechanism(let o)? = i { o == id } else { false }
}

private func isMove(_ i: CanvasView.Interaction?) -> Bool {
    if case .move? = i { true } else { false }
}

private func isPending(_ i: CanvasView.Interaction?) -> Bool {
    if case .pending? = i { true } else { false }
}

// MARK: Routing

@Test @MainActor func routeMechanismDragOnPinnedBar() {
    var fb = fourBarDocument()
    let loose = ShapeObject(kind: .rectangle, start: v(60, 20), end: v(80, 40))
    fb.doc.objects.append(.shape(loose))
    let (view, _) = canvas(fb.doc, select: [fb.crank])
    let mid = (fb.a + fb.b) / 2
    #expect(isMechanism(view.route(isPencil: true, at: point(view, mid)), fb.crank))
    #expect(isMechanism(view.route(isPencil: false, at: point(view, mid)), fb.crank)) // finger selects too
    // Grabbed at B (crank and coupler both there): only the selected crank is taken; the unselected pin is not.
    #expect(isMechanism(view.route(isPencil: true, at: point(view, fb.b)), fb.crank))

    view.selection.ids = [loose.id]
    view.updateSelectionOverlay()
    #expect(isMove(view.route(isPencil: true, at: point(view, v(70, 30)))))

    // Everything selected is pinned and the touch hits no object: as outside the box (tap or lasso).
    view.selection.ids = Set(fb.bars)
    view.updateSelectionOverlay()
    #expect(isPending(view.route(isPencil: false, at: point(view, v(20, 0)))))
}

@Test @MainActor func routeWholeMechanismMovesFreely() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: Set(fb.bars + fb.joints))
    let mid = (fb.a + fb.b) / 2
    #expect(isMove(view.route(isPencil: true, at: point(view, mid))))
    let d = v(10, 5)
    view.beginMove(at: mid)
    view.updateMove(to: mid + d)
    #expect(view.renderer.movingIDs.isSuperset(of: Set(fb.joints))) // joints ride in the preview
    view.endMove()
    for id in fb.bars {
        let s0 = shape(id, in: fb.doc), s1 = shape(id, in: m.document)
        #expect(near(s1.start, s0.start + d, 1e-12) && near(s1.end, s0.end + d, 1e-12))
    }
    for id in fb.joints {
        let j0 = joint(id, in: fb.doc), j1 = joint(id, in: m.document)
        #expect(near(j1.position, j0.position + d, 1e-12))
        for (a0, a1) in zip(j0.anchors, j1.anchors) { #expect(near(a1.point, a0.point + d, 1e-12)) }
    }
    #expect(m.undoManager.undoActionName == "Move")
    m.undoManager.undo()
    #expect(m.document.objects == fb.doc.objects)
    #expect(!m.undoManager.canUndo)
}

// MARK: Mechanism drag

@Test @MainActor func mechanismDragEndToEnd() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.crank])
    view.beginMechanismDrag(object: fb.crank, at: fb.b)
    view.moveMechanism(to: crankTip(-45))
    #expect(view.mechanismDrag != nil)
    #expect(!view.renderer.previewObjects.isEmpty)
    #expect(view.selectionOverlay.layer.isHidden)
    #expect(view.rotateHandleCenter == nil && view.rotateHandle.isHidden)
    view.endMechanismDrag()
    let after = m.document
    #expect(near(shape(fb.crank, in: after).end, crankTip(-45), 1e-3))
    #expect(shape(fb.coupler, in: after) != shape(fb.coupler, in: fb.doc))
    expectPinsHold(after)
    expectLengths(after, fb.bars, like: fb.doc)
    #expect(m.undoManager.undoActionName == "Move Mechanism")
    #expect(view.mechanismDrag == nil && view.renderer.previewObjects.isEmpty)
    #expect(!view.selectionOverlay.layer.isHidden)
    m.undoManager.undo()
    #expect(m.document.objects == fb.doc.objects)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func mechanismDragTapMakesNoEdit() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.crank])
    view.beginMechanismDrag(object: fb.crank, at: fb.b)
    view.moveMechanism(to: crankTip(-89)) // 0.17 mm: under 4 pt
    view.endMechanismDrag()
    #expect(!m.undoManager.canUndo)
    #expect(m.document.objects == fb.doc.objects)
    #expect(view.mechanismDrag == nil && view.renderer.previewObjects.isEmpty)
    #expect(!view.selectionOverlay.layer.isHidden)
}

@Test @MainActor func mechanismDragCancelNoEdit() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.crank])
    view.interaction = .mechanism(fb.crank)
    view.beginMechanismDrag(object: fb.crank, at: fb.b)
    view.moveMechanism(to: crankTip(-45))
    view.cancelInteraction()
    #expect(view.mechanismDrag == nil && view.renderer.previewObjects.isEmpty)
    #expect(!view.selectionOverlay.layer.isHidden)
    #expect(!m.undoManager.canUndo)
    #expect(m.document.objects == fb.doc.objects)
}

@Test @MainActor func outsideUndoCancelsMechanismDrag() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.crank])
    m.perform(.insert([.ink(looseStroke)], at: nil), actionName: "Add")
    view.interaction = .mechanism(fb.crank)
    view.beginMechanismDrag(object: fb.crank, at: fb.b)
    view.moveMechanism(to: crankTip(-45))
    m.undoManager.undo() // e.g. toolbar Undo while the Pencil drags
    #expect(view.mechanismDrag == nil && view.renderer.previewObjects.isEmpty)
    #expect(!view.selectionOverlay.layer.isHidden)
    view.moveMechanism(to: crankTip(-30))
    view.endMechanismDrag()
    #expect(m.document.objects == fb.doc.objects)
    #expect(m.undoManager.canRedo)
}

@Test @MainActor func looseObjectsInPartialSelectionStay() {
    var fb = fourBarDocument()
    fb.doc.objects.append(.ink(looseStroke))
    let (view, m) = canvas(fb.doc, select: [fb.crank, looseStroke.id])
    #expect(isMechanism(view.route(isPencil: true, at: point(view, (fb.a + fb.b) / 2)), fb.crank))
    view.beginMechanismDrag(object: fb.crank, at: fb.b)
    view.moveMechanism(to: crankTip(-45))
    view.endMechanismDrag()
    #expect(m.undoManager.undoActionName == "Move Mechanism")
    #expect(object(looseStroke.id, in: m.document) == .ink(looseStroke))
    #expect(shape(fb.crank, in: m.document) != shape(fb.crank, in: fb.doc))
}

@Test @MainActor func looseMoveInPartialSelectionLeavesPinnedBodies() {
    var fb = fourBarDocument()
    fb.doc.objects.append(.ink(looseStroke))
    let (view, m) = canvas(fb.doc, select: [fb.crank, looseStroke.id])
    let on = v(10, 30)
    #expect(isMove(view.route(isPencil: true, at: point(view, on))))
    view.beginMove(at: on)
    view.updateMove(to: on + v(5, 5))
    view.endMove()
    guard case .ink(let s)? = object(looseStroke.id, in: m.document) else { Issue.record("no stroke"); return }
    #expect(near(s.points[0].position, looseStroke.points[0].position + v(5, 5), 1e-12))
    #expect(shape(fb.crank, in: m.document) == shape(fb.crank, in: fb.doc))
    #expect(m.undoManager.undoActionName == "Move")
}

/// Three bars on one hinge P, one of them grounded at G: dragging another keeps the shared pivot together.
@Test @MainActor func sharedPivotOfThreeAnchorsHolds() {
    let g = v(0, 0), p = v(10, 0), x = v(10, 10), y = v(20, 0)
    let bar1 = ShapeObject(kind: .line, start: g, end: p)
    let bar2 = ShapeObject(kind: .line, start: p, end: x)
    let bar3 = ShapeObject(kind: .line, start: p, end: y)
    let ground = Joint(position: g, anchors: [JointAnchor(object: bar1.id, point: g)], grounded: true)
    let hinge = Joint(position: p, anchors: [bar1, bar2, bar3].map { JointAnchor(object: $0.id, point: p) })
    let doc = SketchDocument(objects: [.shape(bar1), .shape(bar2), .shape(bar3), .joint(ground), .joint(hinge)])
    let (view, m) = canvas(doc, select: [bar2.id])
    #expect(isMechanism(view.route(isPencil: true, at: point(view, (p + x) / 2)), bar2.id))
    view.beginMechanismDrag(object: bar2.id, at: x)
    view.moveMechanism(to: x + v(3, -2))
    view.endMechanismDrag()
    #expect(m.undoManager.undoActionName == "Move Mechanism")
    let j = joint(hinge.id, in: m.document)
    #expect(j.anchors.count == 3)
    for a in j.anchors { #expect(near(a.point, j.anchors[0].point)) }
    expectPinsHold(m.document)
    expectLengths(m.document, [bar1.id, bar2.id, bar3.id], like: doc)
    #expect(shape(bar2.id, in: m.document) != bar2)
}

/// A part plugged into the dragged board but pinned to something else stays with its pin.
@Test @MainActor func pinnedPluggedPartDoesNotRide() {
    let boardDef = PartDefinition.fixtureBreadboardMini(), moduleDef = PartDefinition.fixtureModule()
    let board = PartInstance(definitionKey: boardDef.key, center: v(40, 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: v(40, 0))
    module.center = module.center + (connectorPositions(board, boardDef)["c0r1"]! - connectorPositions(module, moduleDef)["VCC"]!)
    let holder = ShapeObject(kind: .rectangle, start: module.center - v(2, 2), end: module.center + v(2, 2))
    let pivot = board.center + v(-6, -7)
    let ground = Joint(position: pivot, anchors: [JointAnchor(object: board.id, point: pivot)], grounded: true)
    let pin = Joint(position: module.center, anchors: [JointAnchor(object: module.id, point: module.center),
                                                       JointAnchor(object: holder.id, point: module.center)])
    let doc = SketchDocument(objects: [.part(board), .part(module), .shape(holder), .joint(ground), .joint(pin)],
                             parts: [boardDef.key: boardDef, moduleDef.key: moduleDef])
    #expect(!contacts(in: doc).isEmpty)
    let (view, m) = canvas(doc, select: [board.id])
    let grab = board.center + v(6, 7)
    view.beginMechanismDrag(object: board.id, at: grab)
    view.moveMechanism(to: pivot + (grab - pivot).rotated(by: 0.5))
    #expect(!(view.mechanismDrag?.replacements.contains { $0.id == module.id } ?? true))
    view.endMechanismDrag()
    #expect(m.undoManager.undoActionName == "Move Mechanism")
    #expect(object(board.id, in: m.document) != .part(board))
    #expect(object(module.id, in: m.document) == .part(module))
    #expect(object(holder.id, in: m.document) == .shape(holder))
    #expect(joint(pin.id, in: m.document) == pin)
    expectPinsHold(m.document)
}

// MARK: Pin move

@Test @MainActor func pinMoveRelocatesAnchors() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.jointB])
    guard case .pinMove(let id)? = view.route(isPencil: true, at: point(view, fb.b)), id == fb.jointB else {
        Issue.record("expected .pinMove"); return
    }
    view.beginPinMove(fb.jointB, at: fb.b)
    view.movePin(to: fb.b + v(3, 0))
    #expect(view.renderer.previewObjects[fb.jointB] != nil)
    #expect(view.selectionOverlay.layer.isHidden)
    view.endPinMove(at: fb.b + v(3, 0))
    let j = joint(fb.jointB, in: m.document)
    #expect(near(j.position, fb.b + v(3, 0), 1e-12))
    #expect(j.anchors.count == 2)
    for a in j.anchors { #expect(near(a.point, fb.b + v(3, 0), 1e-12)) }
    for id in fb.bars { #expect(shape(id, in: m.document) == shape(id, in: fb.doc)) }
    #expect(m.undoManager.undoActionName == "Move Pin")
    #expect(view.renderer.previewObjects.isEmpty && !view.selectionOverlay.layer.isHidden)
}

@Test @MainActor func pinMoveTapMakesNoEdit() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.jointB])
    view.beginPinMove(fb.jointB, at: fb.b)
    view.movePin(to: fb.b + v(0.2, 0))
    view.endPinMove(at: fb.b + v(0.2, 0))
    #expect(!m.undoManager.canUndo)
    #expect(view.renderer.previewObjects.isEmpty)
}

@Test @MainActor func pinMoveSnapsToGridAndMovesLocks() {
    let fb = fourBarDocument()
    let lock = Joint(kind: .fixed, position: v(20, -20), anchors: [JointAnchor(object: fb.coupler, point: v(20, -20))],
                     grounded: true)
    var doc = fb.doc
    doc.objects.append(.joint(lock))
    let (view, m) = canvas(doc, select: [lock.id])
    view.snapsToGrid = true
    view.beginPinMove(lock.id, at: v(20, -20))
    view.movePin(to: v(26, -17))
    view.endPinMove(at: v(26, -17))
    let j = joint(lock.id, in: m.document)
    #expect(j.position == v(30, -20) && j.anchors[0].point == v(30, -20))
    #expect(m.undoManager.undoActionName == "Move Pin")
}

@Test @MainActor func pinMoveCancelNoEdit() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.jointB])
    view.interaction = .pinMove(fb.jointB)
    view.beginPinMove(fb.jointB, at: fb.b)
    view.movePin(to: fb.b + v(3, 0))
    view.cancelInteraction()
    #expect(view.renderer.previewObjects.isEmpty && !view.selectionOverlay.layer.isHidden)
    #expect(!m.undoManager.canUndo)
}

// MARK: Rotation rules

@Test @MainActor func rotateHandleHiddenWhenPinned() throws {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.crank])
    #expect(view.rotateHandleCenter == nil)
    view.selection.ids = Set(fb.bars)
    view.updateSelectionOverlay()
    #expect(view.rotateHandleCenter == nil)
    view.selection.ids = Set(fb.bars + fb.joints)
    view.updateSelectionOverlay()
    let handle = try #require(view.rotateHandleCenter)
    let b = try #require(view.selectionWorldBounds)
    let pivot = v((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2)
    let grab = view.worldPoint(handle)
    let target = pivot + (grab - pivot).rotated(by: .pi / 2)
    view.beginRotate(at: grab)
    view.moveRotate(to: target)
    view.endRotate(at: target)
    #expect(m.undoManager.undoActionName == "Rotate")
    let after = m.document
    for id in fb.joints {
        let j0 = joint(id, in: fb.doc), j1 = joint(id, in: after)
        #expect(near(j1.position, pivot + (j0.position - pivot).rotated(by: .pi / 2)))
    }
    #expect(near(shape(fb.crank, in: after).end, pivot + (fb.b - pivot).rotated(by: .pi / 2)))
    expectPinsHold(after)
    expectLengths(after, fb.bars, like: fb.doc)
}

@Test @MainActor func quarterTurnDisabledWhenPinned() {
    let moduleDef = PartDefinition.fixtureModule()
    let module = PartInstance(definitionKey: moduleDef.key, center: v(10, 10))
    let plate = ShapeObject(kind: .rectangle, start: v(0, 0), end: v(30, 30))
    let pin = Joint(position: v(10, 10), anchors: [JointAnchor(object: module.id, point: v(10, 10)),
                                                   JointAnchor(object: plate.id, point: v(10, 10))])
    let doc = SketchDocument(objects: [.shape(plate), .part(module), .joint(pin)], parts: [moduleDef.key: moduleDef])
    let (view, m) = canvas(doc, select: [module.id])
    view.rotateSelectedParts(clockwise: true)
    #expect(!m.undoManager.canUndo)
    let menu = view.editMenuInteraction(UIEditMenuInteraction(delegate: nil),
                                        menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero),
                                        suggestedActions: [])
    let titles = (menu?.children ?? []).compactMap { ($0 as? UIAction)?.title }
    #expect(!titles.contains("Rotate ↻") && !titles.contains("Rotate ↺"))
    #expect(titles.contains("Delete"))
}

@Test @MainActor func undoTapBlockedDuringMechanismAndPinMove() {
    #expect(!CanvasView.allowsUndoTap(during: .mechanism(.new())))
    #expect(!CanvasView.allowsUndoTap(during: .pinMove(.new())))
}

/// A free move carries plugged parts, but not one pinned elsewhere: its pin holds.
@Test @MainActor func freeMoveDoesNotCarryPinnedPart() {
    let boardDef = PartDefinition.fixtureBreadboardMini(), moduleDef = PartDefinition.fixtureModule()
    let board = PartInstance(definitionKey: boardDef.key, center: v(40, 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: v(40, 0))
    module.center = module.center + (connectorPositions(board, boardDef)["c0r1"]! - connectorPositions(module, moduleDef)["VCC"]!)
    let holder = ShapeObject(kind: .rectangle, start: module.center - v(2, 2), end: module.center + v(2, 2))
    let pin = Joint(position: module.center, anchors: [JointAnchor(object: module.id, point: module.center),
                                                       JointAnchor(object: holder.id, point: module.center)])
    let doc = SketchDocument(objects: [.part(board), .part(module), .shape(holder), .joint(pin)],
                             parts: [boardDef.key: boardDef, moduleDef.key: moduleDef])
    let (view, m) = canvas(doc, select: [board.id])
    #expect(view.movingSet([board.id]) == [board.id])
    view.beginMove(at: board.center)
    view.updateMove(to: board.center + v(20, 0))
    view.endMove()
    guard case .part(let b1)? = object(board.id, in: m.document) else { Issue.record("no board"); return }
    #expect(near(b1.center, board.center + v(20, 0), 1e-12))
    #expect(object(module.id, in: m.document) == .part(module))
    #expect(joint(pin.id, in: m.document) == pin)
}

/// A free move carries a plugged module together with its whole group; a group with a pinned member stays.
@Test @MainActor func freeMoveCarriesGroupedPluggedModuleWithItsGroup() {
    let boardDef = PartDefinition.fixtureBreadboardMini(), moduleDef = PartDefinition.fixtureModule()
    let board = PartInstance(definitionKey: boardDef.key, center: v(40, 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: v(40, 0))
    module.center = module.center + (connectorPositions(board, boardDef)["c0r1"]! - connectorPositions(module, moduleDef)["VCC"]!)
    let label = TextObject(text: "U1", position: v(70, 20))
    let group = ObjectGroup(members: [module.id, label.id])
    let doc = SketchDocument(objects: [.part(board), .part(module), .text(label)],
                             parts: [boardDef.key: boardDef, moduleDef.key: moduleDef], groups: [group])
    let (view, m) = canvas(doc, select: [board.id])
    #expect(view.movingSet([board.id]) == [board.id, module.id, label.id])
    let d = v(20, 0)
    view.beginMove(at: board.center)
    view.updateMove(to: board.center + d)
    #expect(view.renderer.movingIDs.contains(label.id)) // the label previews with its module
    view.endMove()
    guard case .part(let m1)? = object(module.id, in: m.document), case .text(let t1)? = object(label.id, in: m.document)
    else { Issue.record("missing"); return }
    #expect(near(m1.center, module.center + d, 1e-12))
    #expect(near(t1.position, label.position + d, 1e-12))
    #expect(contacts(in: m.document).count == contacts(in: doc).count)

    // The label pinned to the background: the group holds, the module is not carried away from it.
    let hold = Joint(position: label.position, anchors: [JointAnchor(object: label.id, point: label.position)],
                     grounded: true)
    var pinned = doc
    pinned.objects.append(.joint(hold))
    let (view2, _) = canvas(pinned, select: [board.id])
    #expect(view2.movingSet([board.id]) == [board.id])
}

/// A group without pins in a partial mechanism selection is loose: a mechanism drag leaves it, a drag on it moves
/// only the group.
@Test @MainActor func unpinnedGroupInMechanismSelectionIsLoose() {
    var fb = fourBarDocument()
    let box = ShapeObject(kind: .rectangle, start: v(60, 20), end: v(80, 40))
    fb.doc.objects += [.ink(looseStroke), .shape(box)]
    let group = ObjectGroup(members: [looseStroke.id, box.id])
    fb.doc.groups = [group]
    let selected: Set<ObjectID> = [fb.crank, looseStroke.id, box.id]
    let (view, m) = canvas(fb.doc, select: selected)
    #expect(view.freeMoveIDs() == [looseStroke.id, box.id])
    #expect(isMechanism(view.route(isPencil: true, at: point(view, (fb.a + fb.b) / 2)), fb.crank))
    view.beginMechanismDrag(object: fb.crank, at: fb.b)
    view.moveMechanism(to: crankTip(-45))
    #expect(!(view.mechanismDrag?.replacements.contains { group.members.contains($0.id) } ?? true))
    view.endMechanismDrag()
    #expect(m.undoManager.undoActionName == "Move Mechanism")
    #expect(object(box.id, in: m.document) == .shape(box))
    #expect(object(looseStroke.id, in: m.document) == .ink(looseStroke))

    let (view2, m2) = canvas(fb.doc, select: selected)
    let on = v(60, 30) // on the box outline
    #expect(isMove(view2.route(isPencil: true, at: point(view2, on))))
    view2.beginMove(at: on)
    view2.updateMove(to: on + v(5, 5))
    view2.endMove()
    #expect(object(box.id, in: m2.document) == .shape(box).translated(by: v(5, 5)))
    #expect(object(looseStroke.id, in: m2.document) == .ink(looseStroke).translated(by: v(5, 5)))
    #expect(shape(fb.crank, in: m2.document) == shape(fb.crank, in: fb.doc))
}

// MARK: Fix round 1

/// Bar 1 (0,0)-(40,20) grounded at (0,0); bar 2 (0,20)-(40,0) grounded at (40,0), crossing bar 1's box.
private func crossedBars() -> (doc: SketchDocument, bar1: ShapeObject, bar2: ShapeObject) {
    let bar1 = ShapeObject(kind: .line, start: v(0, 0), end: v(40, 20))
    let bar2 = ShapeObject(kind: .line, start: v(0, 20), end: v(40, 0))
    let g1 = Joint(position: v(0, 0), anchors: [JointAnchor(object: bar1.id, point: v(0, 0))], grounded: true)
    let g2 = Joint(position: v(40, 0), anchors: [JointAnchor(object: bar2.id, point: v(40, 0))], grounded: true)
    return (SketchDocument(objects: [.shape(bar1), .shape(bar2), .joint(g1), .joint(g2)]), bar1, bar2)
}

@Test @MainActor func tapInsidePinnedSelectionBoxRetargets() {
    let (doc, bar1, bar2) = crossedBars()
    let (view, _) = canvas(doc, select: [bar1.id])
    let p = point(view, v(5, 17.5)) // on bar 2 only, inside bar 1's box
    guard case .pending(let start)? = view.route(isPencil: false, at: p) else { Issue.record("expected .pending"); return }
    view.handleTap(at: start) // release of the pending tap
    #expect(view.selection.ids == [bar2.id])
}

@Test @MainActor func tapOnEmptySpaceInsidePinnedBoxClears() {
    let (doc, bar1, _) = crossedBars()
    let (view, _) = canvas(doc, select: [bar1.id])
    let p = point(view, v(35, 12))
    guard case .pending(let start)? = view.route(isPencil: true, at: p) else { Issue.record("expected .pending"); return }
    view.handleTap(at: start)
    #expect(view.selection.ids.isEmpty)
}

@Test @MainActor func tapOnPinnedBoardHoleHighlightsNet() {
    let boardDef = PartDefinition.fixtureBreadboardMini()
    let board = PartInstance(definitionKey: boardDef.key, center: v(40, 0))
    let pivot = board.center + v(-6, -7)
    let ground = Joint(position: pivot, anchors: [JointAnchor(object: board.id, point: pivot)], grounded: true)
    let doc = SketchDocument(objects: [.part(board), .joint(ground)], parts: [boardDef.key: boardDef])
    let (view, m) = canvas(doc, select: [board.id])
    let hole = connectorPositions(board, boardDef)["c1r1"]!
    #expect(isMechanism(view.route(isPencil: true, at: point(view, hole)), board.id))
    view.beginMechanismDrag(object: board.id, at: hole)
    view.endMechanismDrag()
    #expect(view.netHighlight.anchor == ConnectorRef(part: board.id, connector: "c1r1"))
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func pinTapRetargetsLikeAMoveTap() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.jointB, fb.jointC])
    view.beginPinMove(fb.jointB, at: fb.b)
    view.endPinMove(at: fb.b)
    #expect(view.selection.ids == [fb.jointB, fb.jointC]) // tap on a selected pin keeps the selection
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func pinMoveOnlyForPinOnlySelection() {
    let fb = fourBarDocument()
    let (view, _) = canvas(fb.doc, select: [fb.jointB])
    let b = point(view, fb.b)
    guard case .pinMove(let id)? = view.route(isPencil: true, at: b), id == fb.jointB else {
        Issue.record("expected .pinMove"); return
    }
    view.selection.ids = [fb.jointB, fb.crank]
    view.updateSelectionOverlay()
    #expect(isMechanism(view.route(isPencil: true, at: b), fb.crank))
    view.selection.ids = Set(fb.bars + fb.joints)
    view.updateSelectionOverlay()
    #expect(isMove(view.route(isPencil: true, at: b)))
    // Several pins selected (pins only): the one under the touch moves.
    view.selection.ids = [fb.jointB, fb.jointC]
    view.updateSelectionOverlay()
    guard case .pinMove(let c)? = view.route(isPencil: true, at: point(view, fb.c)), c == fb.jointC else {
        Issue.record("expected .pinMove of C"); return
    }
}

@Test @MainActor func quarterTurnDisabledForAnchoredPartEvenWhenWholeMechanismSelected() {
    let moduleDef = PartDefinition.fixtureModule()
    let module = PartInstance(definitionKey: moduleDef.key, center: v(10, 10))
    let plate = ShapeObject(kind: .rectangle, start: v(0, 0), end: v(30, 30))
    let pin = Joint(position: v(10, 10), anchors: [JointAnchor(object: module.id, point: v(10, 10)),
                                                   JointAnchor(object: plate.id, point: v(10, 10))])
    let doc = SketchDocument(objects: [.shape(plate), .part(module), .joint(pin)], parts: [moduleDef.key: moduleDef])
    let (view, m) = canvas(doc, select: [module.id, plate.id, pin.id])
    func rotateTitles() -> [String] {
        let menu = view.editMenuInteraction(UIEditMenuInteraction(delegate: nil),
                                            menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero),
                                            suggestedActions: [])
        return (menu?.children ?? []).compactMap { ($0 as? UIAction)?.title }.filter { $0.hasPrefix("Rotate") }
    }
    view.rotateSelectedParts(clockwise: true)
    #expect(!m.undoManager.canUndo)
    #expect(rotateTitles().isEmpty)
    #expect(view.rotateHandleCenter != nil) // the handle turns the pin too

    // Anchored through its group: the module is grouped with a grounded plate.
    let lone = PartInstance(definitionKey: moduleDef.key, center: v(60, 10))
    let base = ShapeObject(kind: .rectangle, start: v(50, 0), end: v(80, 30))
    let ground = Joint(position: v(70, 20), anchors: [JointAnchor(object: base.id, point: v(70, 20))], grounded: true)
    let group = ObjectGroup(members: [lone.id, base.id])
    let doc2 = SketchDocument(objects: [.shape(base), .part(lone), .joint(ground)], parts: [moduleDef.key: moduleDef],
                              groups: [group])
    let (view2, m2) = canvas(doc2, select: [lone.id, base.id, ground.id])
    view2.rotateSelectedParts(clockwise: false)
    #expect(!m2.undoManager.canUndo)
}

@Test @MainActor func rotateHandleHiddenForPinOnlySelection() {
    let fb = fourBarDocument()
    let (view, _) = canvas(fb.doc, select: [fb.jointB, fb.jointC])
    #expect(view.rotateHandleCenter == nil)
    view.selection.ids = [fb.jointA]
    view.updateSelectionOverlay()
    #expect(view.rotateHandleCenter == nil)
}

@Test @MainActor func rotateHandleShownForPartInJointFreeDocument() {
    let def = PartDefinition.fixtureModule()
    let module = PartInstance(definitionKey: def.key, center: v(10, 10))
    let doc = SketchDocument(objects: [.part(module), .ink(looseStroke)], parts: [def.key: def])
    let (view, _) = canvas(doc, select: [module.id])
    #expect(view.rotateHandleCenter != nil)
}

@Test @MainActor func rotateHandleHiddenWhenCarriedPartPinnedOutside() {
    let boardDef = PartDefinition.fixtureBreadboardMini(), moduleDef = PartDefinition.fixtureModule()
    let board = PartInstance(definitionKey: boardDef.key, center: v(40, 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: v(40, 0))
    module.center = module.center + (connectorPositions(board, boardDef)["c0r1"]! - connectorPositions(module, moduleDef)["VCC"]!)
    let holder = ShapeObject(kind: .rectangle, start: module.center - v(2, 2), end: module.center + v(2, 2))
    let pin = Joint(position: module.center, anchors: [JointAnchor(object: module.id, point: module.center),
                                                       JointAnchor(object: holder.id, point: module.center)])
    let parts = [boardDef.key: boardDef, moduleDef.key: moduleDef]
    let free = SketchDocument(objects: [.part(board), .part(module), .shape(holder)], parts: parts)
    let (control, _) = canvas(free, select: [board.id])
    #expect(control.rotateHandleCenter != nil)
    var pinned = free
    pinned.objects.append(.joint(pin))
    let (view, _) = canvas(pinned, select: [board.id])
    #expect(view.rotateHandleCenter == nil)
    if case .rotate? = view.route(isPencil: true, at: CGPoint(x: 0, y: 0)) { Issue.record("rotate routed") }
}

@Test @MainActor func mechanismDragKeepsContactsAndWireAttachments() {
    let boardDef = PartDefinition.fixtureBreadboardMini(), moduleDef = PartDefinition.fixtureModule()
    let board = PartInstance(definitionKey: boardDef.key, center: v(40, 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: v(40, 0))
    let holes = connectorPositions(board, boardDef)
    module.center = module.center + (holes["c0r1"]! - connectorPositions(module, moduleDef)["VCC"]!)
    let pins = connectorPositions(module, moduleDef)
    let wire = Wire(start: WireEnd(position: pins["SCL"]!, attachment: .connector(part: module.id, connector: "SCL")),
                    end: WireEnd(position: v(80, 30)))
    let jumper = Wire(start: WireEnd(position: pins["GND"]!, attachment: .connector(part: module.id, connector: "GND")),
                      end: WireEnd(position: holes["c3r4"]!, attachment: .connector(part: board.id, connector: "c3r4")))
    let pivot = board.center + v(-6, -7)
    let ground = Joint(position: pivot, anchors: [JointAnchor(object: board.id, point: pivot)], grounded: true)
    let defs = [boardDef.key: boardDef, moduleDef.key: moduleDef]
    let doc = SketchDocument(objects: [.part(board), .part(module), .wire(wire), .wire(jumper), .joint(ground)],
                             parts: defs)
    let before = contacts(in: doc)
    #expect(!before.isEmpty)
    let (view, m) = canvas(doc, select: [board.id])
    let grab = board.center + v(6, 7)
    view.beginMechanismDrag(object: board.id, at: grab)
    view.moveMechanism(to: pivot + (grab - pivot).rotated(by: 0.6))
    view.endMechanismDrag()
    #expect(m.undoManager.undoActionName == "Move Mechanism")
    let after = m.document
    #expect(object(board.id, in: after) != .part(board))
    #expect(contacts(in: after) == before)
    var parts: [ObjectID: PartInstance] = [:]
    for case .part(let p) in after.objects { parts[p.id] = p }
    for case .wire(let w) in after.objects {
        guard case .wire(let w0)? = object(w.id, in: doc) else { Issue.record("wire gone"); continue }
        #expect(w.start.attachment == w0.start.attachment && w.end.attachment == w0.end.attachment)
        for end in [w.start, w.end] {
            guard case .connector(let part, let connector)? = end.attachment, let p = parts[part],
                  let def = defs[p.definitionKey] else { continue }
            #expect(near(end.position, connectorPositions(p, def)[connector]!, 1e-9))
        }
    }
}

// MARK: Touch path

@Test @MainActor func mechanismDragThroughTouchHandlers() {
    let fb = fourBarDocument()
    let (view, m) = canvas(fb.doc, select: [fb.crank])
    let touch = FakeTouch(at: point(view, fb.b))
    view.drive(touch, from: point(view, fb.b), through: [crankTip(-80), crankTip(-60), crankTip(-45)].map { point(view, $0) })
    #expect(view.interaction == nil && view.mechanismDrag == nil && view.renderer.previewObjects.isEmpty)
    #expect(near(shape(fb.crank, in: m.document).end, crankTip(-45), 1e-2))
    expectPinsHold(m.document)
    #expect(m.undoManager.undoActionName == "Move Mechanism")
    m.undoManager.undo()
    #expect(m.document.objects == fb.doc.objects)
    #expect(!m.undoManager.canUndo)
}

// MARK: Selection box during a loose move

@MainActor private func viewRect(_ view: CanvasView, _ b: Rect) -> CGRect {
    let a = point(view, v(b.minX, b.minY)), c = point(view, v(b.maxX, b.maxY))
    return CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
}

private func expectRect(_ a: CGRect?, _ b: CGRect, _ label: String) {
    guard let a else { Issue.record("no rect \(label)"); return }
    #expect(abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.maxX - b.maxX) < 1e-6
            && abs(a.maxY - b.maxY) < 1e-6, "\(label): \(a) vs \(b)")
}

@Test @MainActor func selectionBoxFollowsLooseMoveOfPartlyPinnedSelection() {
    var fb = fourBarDocument()
    fb.doc.objects.append(.ink(looseStroke))
    let (view, _) = canvas(fb.doc, select: [fb.crank, looseStroke.id])
    let crankBox = bounds(of: .shape(shape(fb.crank, in: fb.doc)))
    let strokeBox = bounds(of: .ink(looseStroke))
    let on = v(10, 30), d = v(5, 5)
    view.beginMove(at: on)
    view.updateMove(to: on + d)
    let moved = Rect(origin: strokeBox.origin + d, size: strokeBox.size)
    expectRect(view.selectionViewRect, viewRect(view, crankBox.union(moved)), "during")
    view.endMove()
    let after = view.selectionWorldBounds!
    #expect(after == crankBox.union(moved))
    expectRect(view.selectionViewRect, viewRect(view, after), "after")
}

// MARK: Empty space inside a mixed selection box

@Test @MainActor func dragOnEmptySpaceInMixedBoxMovesLooseObjects() {
    var fb = fourBarDocument()
    let other = InkStroke(points: [InkPoint(position: v(5, 15), pressure: 0.5, time: 0),
                                   InkPoint(position: v(12, 15), pressure: 0.5, time: 0.1)], tool: .pen, baseWidth: 0.5)
    fb.doc.objects += [.ink(looseStroke), .ink(other)]
    let selected: Set<ObjectID> = [fb.crank, looseStroke.id]
    let empty = v(15, 5) // inside the box (crank + stroke), on nothing
    let (view, m) = canvas(fb.doc, select: selected)
    #expect(view.hitObjects(atWorld: empty).isEmpty)
    #expect(isMove(view.route(isPencil: false, at: point(view, empty))))
    let d = v(5, 5)
    view.drive(FakeTouch(at: point(view, empty), type: .direct), from: point(view, empty),
               through: [point(view, empty + d / 2), point(view, empty + d)])
    #expect(m.undoManager.undoActionName == "Move")
    #expect(object(looseStroke.id, in: m.document) == .ink(looseStroke).translated(by: d))
    #expect(shape(fb.crank, in: m.document) == shape(fb.crank, in: fb.doc))
    #expect(object(other.id, in: m.document) == .ink(other))
    #expect(view.selection.ids == selected)

    // Taps there behave as today: empty space clears, an unselected object is selected.
    let (tapView, tapModel) = canvas(fb.doc, select: selected)
    tapView.drive(FakeTouch(at: point(tapView, empty), type: .direct), from: point(tapView, empty))
    #expect(tapView.selection.ids.isEmpty)
    tapView.selection.ids = selected
    tapView.updateSelectionOverlay()
    tapView.drive(FakeTouch(at: point(tapView, v(8, 15)), type: .direct), from: point(tapView, v(8, 15)))
    #expect(tapView.selection.ids == [other.id])
    #expect(!tapModel.undoManager.canUndo)
}
