import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

private let bentWire = Wire(start: WireEnd(position: Vec2(x: 0, y: 0)), end: WireEnd(position: Vec2(x: 20, y: 20)),
                            bends: [Vec2(x: 20, y: 0)])

@MainActor private func canvas(_ objects: [SceneObject], parts: [String: PartDefinition] = [:]) -> (CanvasView, DocumentModel) {
    let m = DocumentModel(document: SketchDocument(objects: objects, parts: parts))
    let view = CanvasView(model: m)
    view.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    view.layoutIfNeeded()
    view.toolState = ToolState(kind: .lasso, pencilOnly: true)
    return (view, m)
}

@MainActor private func point(_ view: CanvasView, _ w: Vec2) -> CGPoint {
    let p = view.currentViewport.worldToView(w, viewSize: view.viewSize)
    return CGPoint(x: p.x, y: p.y)
}

@MainActor private func docWire(_ m: DocumentModel) -> Wire {
    for case .wire(let w) in m.document.objects { return w }
    fatalError()
}

@MainActor private func handles(_ view: CanvasView) -> [WireHandle] { view.selectedWireHandles().map(\.handle) }

@Test @MainActor func handlesOnlyForSelectedWires() {
    let (view, _) = canvas([.wire(bentWire)])
    #expect(view.selectedWireHandles().isEmpty)
    view.updateSelectionOverlay()
    #expect(view.wireBendHandles.isHidden)
    view.selection.ids = [bentWire.id]
    view.updateSelectionOverlay()
    let found = view.selectedWireHandles()
    #expect(found.contains { $0.handle == .bend(wire: bentWire.id, index: 0) && $0.position == v(20, 0) })
    #expect(found.contains { $0.handle == .insert(wire: bentWire.id, segment: 0) && $0.position == v(10, 0) })
    #expect(found.contains { $0.handle == .insert(wire: bentWire.id, segment: 1) && $0.position == v(20, 10) })
    #expect(!view.wireBendHandles.isHidden)
    #expect(!view.wireInsertHandles.isHidden)
}

@Test @MainActor func handlesOnAllSelectedWires() {
    let other = Wire(start: WireEnd(position: v(0, 50)), end: WireEnd(position: v(30, 50)), bends: [v(15, 60)])
    let (view, _) = canvas([.wire(bentWire), .wire(other)])
    view.selection.ids = [bentWire.id, other.id]
    let ids = Set(handles(view).map(\.wire))
    #expect(ids == [bentWire.id, other.id])
    #expect(handles(view).contains(.bend(wire: other.id, index: 0)))
}

@Test @MainActor func shortSegmentHasNoInsertHandle() {
    let short = Wire(start: WireEnd(position: v(0, 0)), end: WireEnd(position: v(1, 0)))
    let (view, _) = canvas([.wire(short)])
    view.selection.ids = [short.id]
    #expect(!handles(view).contains { if case .insert = $0 { true } else { false } })
    #expect(view.wireHandle(at: point(view, v(0.5, 0))) == nil)
}

@Test @MainActor func routeHandleBeatsMove() {
    let (view, _) = canvas([.wire(bentWire)])
    view.selection.ids = [bentWire.id]
    for isPencil in [true, false] {
        guard case .wireBend(let h)? = view.route(isPencil: isPencil, at: point(view, v(20, 0))) else {
            Issue.record("expected bend drag \(isPencil)"); return
        }
        #expect(h == .bend(wire: bentWire.id, index: 0))
        guard case .wireBend(let i)? = view.route(isPencil: isPencil, at: point(view, v(10, 0))) else {
            Issue.record("expected insert drag \(isPencil)"); return
        }
        #expect(i == .insert(wire: bentWire.id, segment: 0))
        guard case .move? = view.route(isPencil: isPencil, at: point(view, v(12, 12))) else {
            Issue.record("expected move \(isPencil)"); return
        }
    }
}

@Test @MainActor func routeLegEndBeatsBend() {
    let def = PartDefinition.fixtureResistor()
    let r = PartInstance(definitionKey: def.key, center: .zero, label: "R1")
    let leg = connectorPositions(r, def)["a"]!
    let w = Wire(start: WireEnd(position: v(-20, -20)), end: WireEnd(position: v(-20, 20)), bends: [leg])
    let (view, _) = canvas([.part(r), .wire(w)], parts: [def.key: def])
    view.selection.ids = [r.id, w.id]
    guard case .leg(let ref)? = view.route(isPencil: true, at: point(view, leg)) else {
        Issue.record("expected leg drag"); return
    }
    #expect(ref.connector == "a")
}

@Test @MainActor func noHandlesOutsideSelectionMode() {
    let (view, _) = canvas([.wire(bentWire)])
    view.selection.ids = [bentWire.id]
    view.toolState = ToolState(kind: .wire, pencilOnly: true)
    if case .wireBend? = view.route(isPencil: true, at: point(view, v(20, 0))) { Issue.record("wire tool dragged bend") }
    view.toolState = ToolState(kind: .ink(.pen), pencilOnly: true)
    if case .wireBend? = view.route(isPencil: true, at: point(view, v(20, 0))) { Issue.record("ink tool dragged bend") }
    // Finger in Pencil-only mode selects, so it may drag bends.
    guard case .wireBend? = view.route(isPencil: false, at: point(view, v(20, 0))) else {
        Issue.record("finger selection should drag bend"); return
    }
}

@Test @MainActor func dragBendEndToEnd() {
    let (view, m) = canvas([.wire(bentWire)])
    view.selection.ids = [bentWire.id]
    view.beginWireBendDrag(.bend(wire: bentWire.id, index: 0), at: v(20, 0))
    view.moveWireBend(to: v(25, 5))
    #expect(view.bendPreview?.bends == [v(25, 5)])
    #expect(view.selectedWireHandles().contains { $0.handle == .bend(wire: bentWire.id, index: 0) && $0.position == v(25, 5) })
    view.endWireBendDrag(at: v(25, 5))
    #expect(docWire(m).bends == [v(25, 5)])
    #expect(view.bendPreview == nil)
    #expect(m.undoManager.undoActionName == "Move Wire Bend")
}

@Test @MainActor func cancelClearsPreview() {
    let (view, m) = canvas([.wire(bentWire)])
    view.selection.ids = [bentWire.id]
    view.interaction = .wireBend(.bend(wire: bentWire.id, index: 0))
    view.beginWireBendDrag(.bend(wire: bentWire.id, index: 0), at: v(20, 0))
    view.moveWireBend(to: v(25, 5))
    view.cancelInteraction()
    #expect(view.bendPreview == nil)
    #expect(!view.bends.isActive)
    #expect(!m.undoManager.canUndo)
    #expect(docWire(m) == bentWire)
}

@Test @MainActor func undoTapBlockedDuringBendDrag() {
    #expect(!CanvasView.allowsUndoTap(during: .wireBend(.bend(wire: ObjectID.new(), index: 0))))
}
