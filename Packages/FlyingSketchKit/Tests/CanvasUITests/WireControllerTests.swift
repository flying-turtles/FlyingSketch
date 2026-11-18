import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private let resistorDef = PartDefinition.fixtureResistor()
private let boardDef = PartDefinition.fixtureBreadboardMini()
@MainActor private var radius: Double { WireController.hitRadius(zoom: 1) }

@MainActor private func wires(_ m: DocumentModel) -> [Wire] {
    m.document.objects.compactMap { if case .wire(let w) = $0 { w } else { nil } }
}

private func ref(_ part: PartInstance, _ id: String) -> WireAttachment { .connector(part: part.id, connector: id) }

/// Resistor at origin (legs a/b ~16 mm apart) and a board far away at (60, 0).
@MainActor private func scene(extra: [SceneObject] = []) -> (WireController, DocumentModel, PartInstance, PartInstance) {
    let r = PartInstance(definitionKey: resistorDef.key, center: .zero, label: "R1")
    let b = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 60, y: 0), label: "BB1")
    let defs = [resistorDef.key: resistorDef, boardDef.key: boardDef]
    let m = DocumentModel(document: SketchDocument(objects: [.part(r), .part(b)] + extra, parts: defs))
    return (WireController(model: m), m, r, b)
}

private func pos(_ p: PartInstance, _ def: PartDefinition, _ id: String) -> Vec2 { connectorPositions(p, def)[id]! }

@Test @MainActor func wireBetweenTwoConnectorsAttachesBothEnds() {
    let (w, m, r, b) = scene()
    let a = pos(r, resistorDef, "a"), hole = pos(b, boardDef, "c1r1")
    w.begin(at: a + Vec2(x: 0.3, y: 0.2), radius: radius)
    _ = w.moveRubberBand(to: hole)
    w.finish(at: hole + Vec2(x: -0.2, y: 0.1), radius: radius)
    let wire = try! #require(wires(m).first)
    #expect(wires(m).count == 1)
    #expect(wire.start == WireEnd(position: a, attachment: ref(r, "a")))
    #expect(wire.end == WireEnd(position: hole, attachment: ref(b, "c1r1")))
    #expect(wire.bends.isEmpty && wire.width == 0.65)
    #expect(!w.isOpen)
    m.undoManager.undo()
    #expect(wires(m).isEmpty)
}

@Test @MainActor func bendsAreKeptInOrder() {
    let (w, m, r, b) = scene()
    let hole = pos(b, boardDef, "c0r0")
    w.begin(at: pos(r, resistorDef, "b"), radius: radius)
    w.addBend(at: Vec2(x: 20, y: 30))
    w.addBend(at: Vec2(x: 40, y: 30))
    #expect(w.openPoints.count == 3)
    #expect(w.moveRubberBand(to: hole).count == 4)
    w.finish(at: hole, radius: radius)
    let wire = try! #require(wires(m).first)
    #expect(wire.bends == [Vec2(x: 20, y: 30), Vec2(x: 40, y: 30)])
    #expect(wire.end.attachment == ref(b, "c0r0"))
    #expect(wire.polyline.count == 4)
}

@Test @MainActor func freeEndedWire() {
    let (w, m, r, _) = scene()
    w.color = RGBAColor(r: 1, g: 0, b: 0)
    w.begin(at: pos(r, resistorDef, "a"), radius: radius)
    w.addBend(at: Vec2(x: -20, y: 10))
    w.addBend(at: Vec2(x: -20, y: 30))
    #expect(w.finishFree())
    let wire = try! #require(wires(m).first)
    #expect(wire.start.attachment == ref(r, "a"))
    #expect(wire.end == WireEnd(position: Vec2(x: -20, y: 30)))
    #expect(wire.bends == [Vec2(x: -20, y: 10)])
    #expect(wire.color == RGBAColor(r: 1, g: 0, b: 0))
    // Free finish over empty space (no connector in range) is also a free end.
    w.begin(at: Vec2(x: 0, y: 50), radius: radius)
    w.finish(at: Vec2(x: 5, y: 50), radius: radius)
    #expect(wires(m).count == 2 && wires(m)[1].start.attachment == nil && wires(m)[1].end.attachment == nil)
}

@Test @MainActor func singlePointWireIsNotInserted() {
    let (w, m, r, _) = scene()
    w.begin(at: Vec2(x: 0, y: 50), radius: radius)
    #expect(!w.finishFree())
    w.begin(at: Vec2(x: 0, y: 50), radius: radius)
    #expect(!w.finish(at: Vec2(x: 0, y: 50), radius: radius))
    // Start and end on the same connector: rejected.
    let a = pos(r, resistorDef, "a")
    w.begin(at: a, radius: radius)
    w.addBend(at: Vec2(x: -20, y: 20))
    #expect(!w.finish(at: a, radius: radius))
    #expect(wires(m).isEmpty && !m.undoManager.canUndo && !w.isOpen)
}

@Test @MainActor func sameConnectorRejectedButSamePartAllowed() {
    let (w, m, r, _) = scene()
    w.begin(at: pos(r, resistorDef, "a"), radius: radius)
    #expect(w.finish(at: pos(r, resistorDef, "b"), radius: radius))
    #expect(wires(m).count == 1)
}

@Test @MainActor func nearestConnectorWinsAndTiesAreDeterministic() {
    let (w, _, _, b) = scene()
    let h = pos(b, boardDef, "c0r0")
    // 2.54 mm pitch: a point 0.5 mm from c0r0 toward c0r1 snaps to c0r0.
    let hit = w.connector(near: h + Vec2(x: 0, y: 0.5), radius: 1.5)
    #expect(hit?.0.connector == "c0r0")
    // Exactly midway: earlier declaration order wins.
    let mid = (h + pos(b, boardDef, "c0r1")) * 0.5
    #expect(w.connector(near: mid, radius: 1.5)?.0.connector == "c0r0")
    #expect(w.connector(near: Vec2(x: 0, y: 200), radius: 5) == nil)
}

@Test @MainActor func hitRadiusScalesWithZoom() {
    #expect(WireController.hitRadius(zoom: 32) == 0.8)
    #expect(WireController.hitRadius(zoom: 1) > 1.8)
    #expect(abs(WireController.hitRadius(zoom: 0.05) - 12 / (Viewport.pointsPerMillimetre * 0.05)) < 1e-9)
}

@Test @MainActor func outsideDocumentChangeCancelsOpenWire() {
    let (w, m, r, _) = scene()
    w.begin(at: pos(r, resistorDef, "a"), radius: radius)
    w.addBend(at: Vec2(x: 0, y: 30))
    #expect(!w.documentDidChange(m.document)) // viewport-style change: same objects
    m.perform(.insert([.shape(ShapeObject(kind: .line, start: .zero, end: Vec2(x: 5, y: 5)))], at: nil), actionName: "x")
    #expect(w.documentDidChange(m.document))
    #expect(!w.isOpen)
}

/// Wire from resistor a (attached) to a free end at (-30, 20).
@MainActor private func dragScene() -> (WireController, DocumentModel, PartInstance, PartInstance, Wire) {
    let r = PartInstance(definitionKey: resistorDef.key, center: .zero)
    let b = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 60, y: 0))
    let wire = Wire(start: WireEnd(position: connectorPositions(r, resistorDef)["a"]!, attachment: ref(r, "a")),
                    end: WireEnd(position: Vec2(x: -30, y: 20)), bends: [Vec2(x: -30, y: 5)])
    let defs = [resistorDef.key: resistorDef, boardDef.key: boardDef]
    let m = DocumentModel(document: SketchDocument(objects: [.part(r), .part(b), .wire(wire)], parts: defs))
    return (WireController(model: m), m, r, b, wire)
}

@Test @MainActor func dragEndReattaches() {
    let (w, m, _, b, wire) = dragScene()
    #expect(w.beginEndDrag(at: Vec2(x: -30, y: 20.3), radius: radius))
    let hole = pos(b, boardDef, "c3r4")
    let preview = try! #require(w.moveEndDrag(to: hole + Vec2(x: 0.2, y: 0), radius: radius))
    #expect(preview.end == WireEnd(position: hole, attachment: ref(b, "c3r4")))
    #expect(w.finishEndDrag(at: hole + Vec2(x: 0.2, y: 0), radius: radius))
    let moved = wires(m)[0]
    #expect(moved.id == wire.id && moved.end == WireEnd(position: hole, attachment: ref(b, "c3r4")))
    #expect(moved.start == wire.start && moved.bends == wire.bends)
    #expect(wires(m).count == 1)
    m.undoManager.undo()
    #expect(wires(m)[0] == wire)
}

@Test @MainActor func dragEndDetaches() {
    let (w, m, r, _, wire) = dragScene()
    let a = pos(r, resistorDef, "a")
    // The attached start sits exactly on connector a: dragging still grabs the end, not a new wire.
    #expect(w.end(near: a, radius: radius)?.isStart == true)
    #expect(w.beginEndDrag(at: a, radius: radius))
    _ = w.moveEndDrag(to: Vec2(x: 10, y: 40), radius: radius)
    #expect(w.finishEndDrag(at: Vec2(x: 10, y: 40), radius: radius))
    let moved = wires(m)[0]
    #expect(moved.start == WireEnd(position: Vec2(x: 10, y: 40)))
    #expect(moved.end == wire.end)
}

@Test @MainActor func endDragTapAndMissEditNothing() {
    let (w, m, _, _, _) = dragScene()
    w.dragSlop = 0.5
    #expect(!w.beginEndDrag(at: Vec2(x: 100, y: 100), radius: radius))
    #expect(w.beginEndDrag(at: Vec2(x: -30, y: 20), radius: radius))
    _ = w.moveEndDrag(to: Vec2(x: -30.1, y: 20), radius: radius)
    #expect(!w.finishEndDrag(at: Vec2(x: -30.1, y: 20), radius: radius))
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func endDragOntoOtherEndsConnectorIsRejected() {
    let (w, m, r, _, _) = dragScene()
    #expect(w.beginEndDrag(at: Vec2(x: -30, y: 20), radius: radius))
    let a = pos(r, resistorDef, "a")
    #expect(!w.finishEndDrag(at: a, radius: radius))
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func routeWireToolRules() {
    let (_, m, _, _, wire) = dragScene()
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    v.toolState.kind = .wire
    let onEnd = v.currentViewport.worldToView(wire.end.position, viewSize: v.viewSize)
    let elsewhere = CGPoint(x: 100, y: 100)
    if case .wireEnd? = v.route(isPencil: true, at: CGPoint(x: onEnd.x, y: onEnd.y)) {} else { Issue.record("expected wireEnd") }
    if case .wire? = v.route(isPencil: true, at: elsewhere) {} else { Issue.record("expected wire") }
    // pencilOnly: a finger does not wire.
    if case .wire? = v.route(isPencil: false, at: elsewhere) { Issue.record("finger wired") }
}

@MainActor private func wireCanvas() -> (CanvasView, DocumentModel, PartInstance, PartInstance) {
    let (_, m, r, b) = scene()
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    v.toolState.kind = .wire
    return (v, m, r, b)
}

@Test @MainActor func canvasSessionBendsThenToolChangeFinishesFree() {
    let (v, m, r, _) = wireCanvas()
    v.toolState.color = RGBAColor(r: 0, g: 0, b: 1)
    v.beginWire(at: pos(r, resistorDef, "a"))
    v.moveWire(to: Vec2(x: -20, y: 20))
    v.endWire(at: Vec2(x: -20, y: 20))            // bend, stays open
    #expect(v.wires.isOpen && wires(m).isEmpty)
    v.endGesture(with: Viewport(center: Vec2(x: 5, y: 5), zoom: 1))                      // pan/zoom persistence must not cancel
    #expect(v.wires.isOpen)
    v.beginWire(at: Vec2(x: 40, y: 80))            // far touch-down continues
    v.endWire(at: Vec2(x: 40, y: 80))
    #expect(v.wires.openPoints.count == 3)
    v.toolState.kind = .eraser                     // tool change: free end
    let wire = try! #require(wires(m).first)
    #expect(wire.start.attachment == ref(r, "a") && wire.bends == [Vec2(x: -20, y: 20)] && wire.end == WireEnd(position: Vec2(x: 40, y: 80)))
    #expect(wire.color == RGBAColor(r: 0, g: 0, b: 1) && !v.wires.isOpen && v.wirePreview == nil)
}

@Test @MainActor func canvasTapOnLastBendFinishesAndUndoCancels() {
    let (v, m, r, _) = wireCanvas()
    v.beginWire(at: pos(r, resistorDef, "b"))
    v.endWire(at: Vec2(x: 30, y: 30))
    v.beginWire(at: Vec2(x: 30, y: 30))
    v.endWire(at: Vec2(x: 30.1, y: 30))            // tap on last bend
    #expect(wires(m).count == 1 && !v.wires.isOpen)

    v.beginWire(at: Vec2(x: 0, y: 60))
    v.endWire(at: Vec2(x: 20, y: 60))
    m.undoManager.undo()                           // outside change cancels the open wire
    #expect(!v.wires.isOpen && wires(m).isEmpty)
}
