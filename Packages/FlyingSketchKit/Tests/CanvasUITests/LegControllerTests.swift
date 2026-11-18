import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private let resistorDef = PartDefinition.fixtureResistor()
private let boardDef = PartDefinition.fixtureBreadboardMini()

/// Resistor at origin (leg a default end (-3,1.25) local), board at (60, 0), wire from leg a to a free point.
@MainActor private func scene() -> (DocumentModel, PartInstance, PartInstance, Wire) {
    let r = PartInstance(definitionKey: resistorDef.key, center: .zero, label: "R1")
    let b = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 60, y: 0), label: "BB1")
    let a = connectorPositions(r, resistorDef)["a"]!
    let w = Wire(start: WireEnd(position: a, attachment: .connector(part: r.id, connector: "a")),
                 end: WireEnd(position: Vec2(x: 0, y: 30)))
    let m = DocumentModel(document: SketchDocument(objects: [.part(r), .part(b), .wire(w)],
                                                   parts: [resistorDef.key: resistorDef, boardDef.key: boardDef]))
    return (m, r, b, w)
}

@MainActor private func part(_ m: DocumentModel, _ id: ObjectID) -> PartInstance {
    for case .part(let p) in m.document.objects where p.id == id { return p }
    fatalError()
}

@MainActor private func wire(_ m: DocumentModel) -> Wire {
    for case .wire(let w) in m.document.objects { return w }
    fatalError()
}

private func hole(_ b: PartInstance, _ id: String) -> Vec2 { connectorPositions(b, boardDef)[id]! }

@Test @MainActor func legSnapsIntoHole() {
    let (m, r, b, _) = scene()
    let h = hole(b, "c1r1")
    let c = LegController(model: m)
    c.begin(part: r.id, connector: "a")
    c.move(to: h + Vec2(x: 0.5, y: -0.4))
    c.end()
    #expect(part(m, r.id).legEnds["a"] == h)
    #expect(contacts(in: m.document).contains(Contact(male: ConnectorRef(part: r.id, connector: "a"),
                                                      female: ConnectorRef(part: b.id, connector: "c1r1"))))
    m.undoManager.undo()
    #expect(part(m, r.id).legEnds["a"] == nil)
}

@Test @MainActor func legReleasedAwayFromHoleStaysWhereReleased() {
    let (m, r, _, _) = scene()
    let c = LegController(model: m)
    c.begin(part: r.id, connector: "a")
    c.move(to: Vec2(x: -20, y: 10))
    c.end()
    #expect(part(m, r.id).legEnds["a"] == Vec2(x: -20, y: 10))
    #expect(m.undoManager.undoActionName == "Bend Leg")
}

@Test @MainActor func legDragUpdatesAttachedWire() {
    let (m, r, b, _) = scene()
    let h = hole(b, "c2r3")
    let c = LegController(model: m)
    c.begin(part: r.id, connector: "a")
    let preview = c.move(to: h)
    #expect(preview.count == 2) // part + wire
    c.end()
    let w = wire(m)
    #expect(w.start.position == h)
    #expect(w.start.attachment == .connector(part: r.id, connector: "a"))
    m.undoManager.undo() // one edit covers part and wire
    #expect(wire(m).start.position != h)
}

@Test @MainActor func cancelLeavesLegUnchanged() {
    let (m, r, _, _) = scene()
    let before = m.document.objects
    let c = LegController(model: m)
    c.begin(part: r.id, connector: "a")
    c.move(to: Vec2(x: 30, y: 30))
    c.cancel()
    c.end()
    #expect(m.document.objects == before)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func snapIgnoresOwnPartAndNoOpWhenUnchanged() {
    let (m, r, _, _) = scene()
    let start = connectorPositions(r, resistorDef)["a"]!
    let c = LegController(model: m)
    c.begin(part: r.id, connector: "a")
    c.move(to: start)
    c.end()
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func legAlreadyInHoleSnappedToSameHoleIsNoOp() {
    let (_, r, b, _) = scene()
    let h = hole(b, "c1r1")
    var plugged = r
    plugged.legEnds["a"] = h
    let m = DocumentModel(document: SketchDocument(objects: [.part(plugged), .part(b)],
                                                   parts: [resistorDef.key: resistorDef, boardDef.key: boardDef]))
    let c = LegController(model: m)
    c.begin(part: r.id, connector: "a")
    c.move(to: h + Vec2(x: 0.3, y: 0.3))
    c.end()
    #expect(!m.undoManager.canUndo)
}

@MainActor private func canvas(_ m: DocumentModel) -> CanvasView {
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    return v
}

@MainActor private func viewPoint(_ v: CanvasView, _ w: Vec2) -> CGPoint {
    let p = v.currentViewport.worldToView(w, viewSize: v.viewSize)
    return CGPoint(x: p.x, y: p.y)
}

@Test @MainActor func handlesShownOnlyForSelectedLeggedParts() {
    let (m, r, b, _) = scene()
    let v = canvas(m)
    #expect(v.legHandles.isHidden)
    v.selection.ids = [b.id]
    v.updateSelectionOverlay()
    #expect(v.legHandles.isHidden)
    v.selection.ids = [r.id]
    v.updateSelectionOverlay()
    #expect(!v.legHandles.isHidden)
    #expect(v.selectedLegEnds().count == 2)
}

@Test @MainActor func routingGivesLegDragPrecedenceForSelectionModes() {
    let (m, r, _, _) = scene()
    let v = canvas(m)
    v.selection.ids = [r.id]
    let end = viewPoint(v, connectorPositions(r, resistorDef)["a"]!)
    for (isPencil, tool) in [(true, ToolState(kind: .lasso, pencilOnly: true)), (false, ToolState(kind: .lasso, pencilOnly: true)),
                             (false, ToolState(kind: .ink(.pen), pencilOnly: true))] {
        v.toolState = tool
        guard case .leg(let ref)? = v.route(isPencil: isPencil, at: end) else { Issue.record("expected leg \(isPencil)"); return }
        #expect(ref.connector == "a")
    }
    // Other tools: legs not draggable.
    v.toolState = ToolState(kind: .ink(.pen), pencilOnly: true)
    if case .leg? = v.route(isPencil: true, at: end) { Issue.record("ink tool dragged leg") }
    // Unselected part: no leg drag.
    v.toolState = ToolState(kind: .lasso, pencilOnly: true)
    v.selection.ids = []
    if case .leg? = v.route(isPencil: true, at: end) { Issue.record("unselected leg dragged") }
}

@Test @MainActor func viewDragSnapsCancelsAndIgnoresTinyTravel() {
    let (m, r, b, _) = scene()
    let v = canvas(m)
    v.selection.ids = [r.id]
    let a = connectorPositions(r, resistorDef)["a"]!
    // Tiny travel: no edit.
    v.beginLegDrag(ConnectorRef(part: r.id, connector: "a"), at: a)
    v.moveLeg(to: a + Vec2(x: 0.1, y: 0))
    v.endLegDrag(at: a + Vec2(x: 0.1, y: 0))
    #expect(!m.undoManager.canUndo)
    // Cancel: preview cleared, no edit.
    v.beginLegDrag(ConnectorRef(part: r.id, connector: "a"), at: a)
    v.moveLeg(to: Vec2(x: 20, y: 20))
    #expect(!v.legPreview.isEmpty)
    v.cancelLegDrag()
    #expect(v.legPreview.isEmpty && !m.undoManager.canUndo)
    // Drop near hole snaps.
    let h = hole(b, "c0r0")
    v.beginLegDrag(ConnectorRef(part: r.id, connector: "a"), at: a)
    v.endLegDrag(at: h + Vec2(x: 0.4, y: 0.4))
    #expect(part(m, r.id).legEnds["a"] == h)
    #expect(m.undoManager.undoActionName == "Bend Leg")
}
