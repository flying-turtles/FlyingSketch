import UIKit
import Testing
import SketchCore
import NetKit
@testable import CanvasUI

private let moduleDef = PartDefinition.fixtureModule()
private let boardDef = PartDefinition.fixtureBreadboardMini()
private let resistorDef = PartDefinition.fixtureResistor()
private let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"2.5mm\"/>".utf8)

private struct Scene {
    var view: CanvasView
    var model: DocumentModel
    var module: PartInstance
    var board: PartInstance
    var resistor: PartInstance
    var wire1: Wire // module.VCC -> board c0r0
    var wire2: Wire // module.SDA -> board c0r4

    func pin(_ id: String) -> CGPoint { viewPoint(connectorPositions(module, moduleDef)[id]!) }
    func hole(_ id: String) -> CGPoint { viewPoint(connectorPositions(board, boardDef)[id]!) }
    func viewPoint(_ w: Vec2) -> CGPoint {
        let v = view.currentViewport.worldToView(w, viewSize: view.viewSize)
        return CGPoint(x: v.x, y: v.y)
    }
}

/// Module at (0,-30); board at (0,30); resistor leg `a` plugged into c0r2 (rides the VCC bus); wire1 VCC-c0r0,
/// wire2 SDA-c0r4 (same bus, so VCC and SDA share a net).
@MainActor private func scene(withWire2: Bool = true) -> Scene {
    let module = PartInstance(definitionKey: moduleDef.key, center: Vec2(x: 0, y: -30), label: "U1")
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 0, y: 30), label: "BB1")
    var r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 40, y: 30), label: "R1")
    let h = connectorPositions(board, boardDef)
    r.legEnds["a"] = h["c0r2"]
    func w(_ pin: String, _ hole: String) -> Wire {
        let p = connectorPositions(module, moduleDef)[pin]!
        return Wire(start: WireEnd(position: p, attachment: .connector(part: module.id, connector: pin)),
                    end: WireEnd(position: h[hole]!, attachment: .connector(part: board.id, connector: hole)))
    }
    let w1 = w("VCC", "c0r0"), w2 = w("SDA", "c0r4")
    let defs = [moduleDef, boardDef, resistorDef]
    var objects: [SceneObject] = [.part(board), .part(module), .part(r), .wire(w1)]
    if withWire2 { objects.append(.wire(w2)) }
    let m = DocumentModel(document: SketchDocument(
        objects: objects, assets: Dictionary(uniqueKeysWithValues: defs.map { ($0.graphicAsset, svg) }),
        parts: Dictionary(uniqueKeysWithValues: defs.map { ($0.key, $0) })))
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    return Scene(view: v, model: m, module: module, board: board, resistor: r, wire1: w1, wire2: w2)
}

@Test @MainActor func tapOnPinHighlightsNet() {
    let s = scene()
    let expected = nets(in: s.model.document).first { $0.members.contains(ConnectorRef(part: s.module.id, connector: "VCC")) }!
    #expect(s.view.highlightNet(at: s.pin("VCC")))
    let h = s.view.netHighlight
    #expect(h.net?.members == expected.members)
    #expect(h.net?.members.contains(ConnectorRef(part: s.module.id, connector: "SDA")) == true)
    #expect(h.net?.members.contains(ConnectorRef(part: s.resistor.id, connector: "a")) == true)
    #expect(h.net?.wires == [s.wire1.id, s.wire2.id])
    #expect(h.info == PinInfo(partLabel: "U1", connectorName: "VCC", role: .power, netName: expected.name,
                              memberCount: expected.members.count))
    #expect(h.info?.summary == "U1 · VCC · power — \(expected.name) (\(expected.members.count) pins)")
    // Overlay: a ring per member, glow per wire; rings use the screen scale.
    let layers = s.view.renderer.netLayers
    #expect(s.view.renderer.netOverlay?.rings.count == expected.members.count)
    #expect(layers.glowLayers.count == 2)
    #expect(layers.rings.path?.isEmpty == false)
    #expect(layers.rings.contentsScale == s.view.traitCollection.displayScale)
}

@Test @MainActor func tapWinsOverSelectingPartAndTapElsewhereClears() {
    let s = scene()
    s.view.selection.ids = [s.module.id]
    s.view.tap(at: s.pin("VCC")) // selection tap path alone still selects
    #expect(s.view.selection.ids.count == 1)
    #expect(s.view.highlightNet(at: s.pin("VCC")))
    #expect(s.view.highlightNet(at: CGPoint(x: 900, y: 1200)) == false)
    #expect(s.view.netHighlight.info == nil)
    #expect(s.view.netHighlight.net == nil)
    #expect(s.view.renderer.netOverlay == nil)
    #expect(s.view.renderer.netLayers.glowLayers.isEmpty)
}

@Test @MainActor func highlightClearsOnEmptyTap() {
    let s = scene()
    s.view.highlightNet(at: s.pin("GND"))
    s.view.highlightNet(at: s.pin("VCC"))
    #expect(s.view.netHighlight.info != nil)
    s.view.tap(at: CGPoint(x: 900, y: 1200)) // plain tap path
    s.view.highlightNet(at: CGPoint(x: 900, y: 1200))
    #expect(s.view.netHighlight.info == nil)
}

@Test @MainActor func unconnectedPinShowsNoConnection() {
    let s = scene()
    #expect(s.view.highlightNet(at: s.pin("GND")))
    #expect(s.view.netHighlight.net == nil)
    #expect(s.view.netHighlight.info?.summary == "U1 · GND · ground — no connection")
    #expect(s.view.renderer.netOverlay?.rings.count == 1)
    #expect(s.view.renderer.netOverlay?.wires.isEmpty == true)
    // Empty breadboard row (R5): no net either.
    #expect(s.view.highlightNet(at: s.hole("c3r3")))
    #expect(s.view.netHighlight.info?.memberCount == 0)
}

@Test @MainActor func highlightUpdatesAfterUndo() {
    let s = scene(withWire2: false)
    let before = nets(in: s.model.document).first { $0.members.contains(ConnectorRef(part: s.module.id, connector: "VCC")) }!
    s.view.highlightNet(at: s.pin("VCC"))
    #expect(s.view.netHighlight.net?.members == before.members)
    // Add wire2 (one edit): the open highlight grows without a new tap.
    s.model.perform(.insert([.wire(s.wire2)], at: nil), actionName: "Add Wire")
    #expect(s.view.netHighlight.net?.members.count == before.members.count + 1)
    #expect(s.view.netHighlight.net?.wires.count == 2)
    #expect(s.view.renderer.netLayers.glowLayers.count == 2)
    s.model.undoManager.undo() // net shrinks back
    #expect(s.view.netHighlight.net?.members == before.members)
    #expect(s.view.netHighlight.info?.memberCount == before.members.count)
    #expect(s.view.renderer.netLayers.glowLayers.count == 1)
    // Remove the first wire: VCC is no longer on a net, the pin info stays; undo brings the net back.
    s.model.perform(.remove([s.wire1.id]), actionName: "Delete")
    #expect(s.view.netHighlight.net == nil)
    #expect(s.view.netHighlight.info?.summary == "U1 · VCC · power — no connection")
    s.model.undoManager.undo()
    #expect(s.view.netHighlight.net?.members == before.members)
}

@Test @MainActor func highlightDisappearsWhenPinIsGone() {
    let s = scene()
    s.view.highlightNet(at: s.pin("VCC"))
    s.view.selection.ids = [s.module.id]
    s.view.deleteSelection()
    #expect(s.view.netHighlight.info == nil)
    #expect(s.view.renderer.netOverlay == nil)
    s.model.undoManager.undo() // pin returns; highlight does not
    #expect(s.view.netHighlight.info == nil)
}

@Test @MainActor func netsRecomputedOnlyWhenDocumentChanged() {
    let s = scene()
    s.view.highlightNet(at: s.pin("VCC"))
    let cached = s.view.netHighlight.cache?.nets
    s.model.setViewport(Viewport(center: Vec2(x: 5, y: 5), zoom: 2)) // viewport-only change
    #expect(s.view.netHighlight.cache?.nets == cached)
    #expect(s.view.netHighlight.info != nil)
    #expect(s.view.renderer.netOverlay != nil)
}

@Test @MainActor func moveDragWithConnectorTapPrefersHighlight() {
    let s = scene()
    s.view.selection.ids = [s.module.id]
    let w = connectorPositions(s.module, moduleDef)["VCC"]!
    s.view.beginMove(at: w)
    s.view.endMove() // unengaged = tap
    #expect(s.view.netHighlight.info?.connectorName == "VCC")
    #expect(s.view.selection.ids == [s.module.id])
}

@Test @MainActor func pencilLassoTapHighlights() {
    let s = scene()
    s.view.toolState.kind = .lasso
    let w = s.view.worldPoint(s.pin("VCC"))
    s.view.lasso.begin(at: w)
    s.view.lasso.move(to: w + Vec2(x: 0.1, y: 0.1))
    #expect(s.view.highlightNetOnLassoTap())
    #expect(s.view.netHighlight.info?.connectorName == "VCC")
    s.view.lasso.begin(at: w)
    s.view.lasso.move(to: w + Vec2(x: 40, y: 0))
    #expect(!s.view.highlightNetOnLassoTap()) // a real lasso falls through
    #expect(s.view.netHighlight.info != nil)
}

@Test @MainActor func previewsHideOverlay() {
    let s = scene()
    s.view.highlightNet(at: s.pin("VCC"))
    #expect(!s.view.renderer.netLayers.rings.isHidden)
    s.view.renderer.setMovePreview(ids: [], offset: .zero, replacing: [.part(s.module)])
    #expect(s.view.renderer.netLayers.rings.isHidden && s.view.renderer.netLayers.glowLayers.allSatisfy(\.isHidden))
    s.view.renderer.setMovePreview(ids: [], offset: .zero)
    #expect(!s.view.renderer.netLayers.rings.isHidden)
}

@Test @MainActor func pinInfoSummaries() {
    #expect(PinInfo(partLabel: "R1", connectorName: "leg1", netName: "N3", memberCount: 4).summary == "R1 · leg1 — N3 (4 pins)")
    #expect(PinInfo(partLabel: "U1", connectorName: "GPIO4", role: .digital, netName: "N3", memberCount: 4).summary
        == "U1 · GPIO4 · digital — N3 (4 pins)")
    #expect(PinInfo(partLabel: "R1", connectorName: "leg1").summary == "R1 · leg1 — no connection")
}

@Test @MainActor func glowSitsDirectlyBelowItsWireAboveParts() {
    let s = scene()
    s.view.highlightNet(at: s.pin("VCC"))
    let r: SceneRenderer = s.view.renderer
    let objects = r.objectsLayer
    let glow = r.netLayers.glowLayers
    #expect(glow.count == 2)
    #expect(glow.allSatisfy { $0.superlayer === objects })
    let doc = s.model.document
    for (i, o) in doc.objects.enumerated() {
        guard case .wire(let w) = o, [s.wire1.id, s.wire2.id].contains(w.id) else { continue }
        // The wire's own glow is at index - 0.5: above every earlier object (the board part), below the wire.
        let wireZ = CGFloat(i)
        #expect(glow.contains { $0.zPosition == wireZ - 0.5 })
        let partsBelow = doc.objects.prefix(i).enumerated().filter { if case .part = $0.element { true } else { false } }
        #expect(partsBelow.allSatisfy { CGFloat($0.offset) < wireZ - 0.5 })
    }
}

@Test @MainActor func legEndTapHighlightsAndDragBends() {
    let s = scene()
    s.view.selection.ids = [s.resistor.id]
    let end = connectorPositions(s.resistor, resistorDef)["b"]! // free leg end, not on a board
    // Tap: grab and release at the same point.
    s.view.beginLegDrag(ConnectorRef(part: s.resistor.id, connector: "b"), at: end)
    s.view.endLegDrag(at: end)
    #expect(s.view.netHighlight.info?.connectorName == "b")
    #expect(s.model.undoManager.canUndo == false)
    // Drag: leg bends, highlight untouched.
    let before = s.view.netHighlight.info
    s.view.beginLegDrag(ConnectorRef(part: s.resistor.id, connector: "b"), at: end)
    s.view.endLegDrag(at: end + Vec2(x: 0, y: 25))
    #expect(s.model.undoManager.undoActionName == "Bend Leg")
    #expect(s.view.netHighlight.info == before)
}
