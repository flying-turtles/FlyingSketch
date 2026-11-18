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
    s.view.selection.ids = [s.module.id]
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

@Test @MainActor func pinOfUnselectedPartSelectsInsteadOfHighlighting() {
    let s = scene()
    #expect(!s.view.highlightNet(at: s.pin("VCC")))
    #expect(s.view.netHighlight.info == nil)
    s.view.fingerTap(at: s.pin("GND")) // first tap selects the part (GND: no wire on top)
    #expect(s.view.selection.ids == [s.module.id])
    #expect(s.view.netHighlight.info == nil)
    s.view.fingerTap(at: s.pin("GND")) // second tap on its pin highlights
    #expect(s.view.netHighlight.info?.connectorName == "GND")
    #expect(s.view.selection.ids == [s.module.id])
    // Another part's pin while the module is selected: selection, no highlight.
    s.view.fingerTap(at: s.hole("c3r3"))
    #expect(s.view.selection.ids == [s.board.id])
    #expect(s.view.netHighlight.info == nil)
}

@Test @MainActor func selectedPinHighlightsAndTapElsewhereClears() {
    let s = scene()
    s.view.selection.ids = [s.module.id]
    #expect(s.view.highlightNet(at: s.pin("VCC")))
    #expect(s.view.highlightNet(at: CGPoint(x: 900, y: 1200)) == false)
    #expect(s.view.netHighlight.info == nil)
    #expect(s.view.netHighlight.net == nil)
    #expect(s.view.renderer.netOverlay == nil)
    #expect(s.view.renderer.netLayers.glowLayers.isEmpty)
}

@Test @MainActor func highlightClearsOnEmptyTap() {
    let s = scene()
    s.view.selection.ids = [s.module.id]
    s.view.highlightNet(at: s.pin("GND"))
    s.view.highlightNet(at: s.pin("VCC"))
    #expect(s.view.netHighlight.info != nil)
    s.view.tap(at: CGPoint(x: 900, y: 1200)) // plain tap path
    s.view.highlightNet(at: CGPoint(x: 900, y: 1200))
    #expect(s.view.netHighlight.info == nil)
}

@Test @MainActor func unconnectedPinShowsNoConnection() {
    let s = scene()
    s.view.selection.ids = [s.module.id, s.board.id]
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
    s.view.selection.ids = [s.module.id]
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
    s.view.selection.ids = [s.module.id]
    s.view.highlightNet(at: s.pin("VCC"))
    s.view.deleteSelection()
    #expect(s.view.netHighlight.info == nil)
    #expect(s.view.renderer.netOverlay == nil)
    s.model.undoManager.undo() // pin returns; highlight does not
    #expect(s.view.netHighlight.info == nil)
}

@Test @MainActor func netsRecomputedOnlyWhenDocumentChanged() {
    let s = scene()
    s.view.selection.ids = [s.module.id]
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
    s.view.selection.ids = [s.module.id]
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
    s.view.selection.ids = [s.module.id]
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
    s.view.selection.ids = [s.module.id]
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

@Test @MainActor func selectedWireEndHighlightsItsNet() {
    let s = scene()
    let endPoint = s.viewPoint(s.wire2.end.position) // board c0r4; the board is not selected
    #expect(!s.view.highlightNet(at: endPoint))
    s.view.selection.ids = [s.wire2.id]
    #expect(s.view.highlightNet(at: endPoint))
    #expect(s.view.netHighlight.anchor == ConnectorRef(part: s.board.id, connector: "c0r4"))
    #expect(s.view.netHighlight.net?.wires.contains(s.wire2.id) == true)
    // A selected wire with two free ends has no net: no highlight, normal selection.
    let loose = Wire(start: WireEnd(position: Vec2(x: 100, y: 100)), end: WireEnd(position: Vec2(x: 120, y: 100)))
    s.model.perform(.insert([.wire(loose)], at: nil), actionName: "Add Wire")
    s.view.selection.ids = [loose.id]
    #expect(!s.view.highlightNet(at: s.viewPoint(loose.start.position)))
    #expect(s.view.netHighlight.info == nil)
}

/// Real catalog geometry: holes 2.54 mm apart, so every tap on a board is within a connector's hit radius.
@Test @MainActor func breadboardTapsSelectFirstThenHighlight() throws {
    let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Catalog/parts")
    func load(_ id: String) throws -> PartDefinition {
        try JSONDecoder().decode(PartDefinition.self, from: Data(contentsOf: catalog.appendingPathComponent("\(id).json")))
    }
    let boardDef = try load("breadboard-full"), resDef = try load("resistor")
    let board = PartInstance(definitionKey: boardDef.key, center: .zero, label: "BB1")
    let holes = connectorPositions(board, boardDef)
    let a = try #require(holes["pin10C"]), b = try #require(holes["pin14C"])
    let res = PartInstance(definitionKey: resDef.key, center: (a + b) * 0.5, label: "R1",
                           legEnds: ["connector0": a, "connector1": b])
    let m = DocumentModel(document: SketchDocument(objects: [.part(board), .part(res)],
                                                   parts: [boardDef.key: boardDef, resDef.key: resDef]))
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    func view(_ w: Vec2) -> CGPoint {
        let p = v.currentViewport.worldToView(w, viewSize: v.viewSize)
        return CGPoint(x: p.x, y: p.y)
    }
    // First tap on the resistor body: selects it, no highlight.
    v.fingerTap(at: view(res.center))
    #expect(v.selection.ids == [res.id])
    #expect(v.netHighlight.info == nil)
    // Tap on the board (a hole away from the resistor): selects the board, no highlight.
    let farHole = try #require(holes["pin30H"])
    v.fingerTap(at: view(farHole))
    #expect(v.selection.ids == [board.id])
    #expect(v.netHighlight.info == nil)
    // Second tap on a hole of the now selected board highlights that hole.
    v.fingerTap(at: view(farHole))
    #expect(v.netHighlight.anchor == ConnectorRef(part: board.id, connector: "pin30H"))
    #expect(v.selection.ids == [board.id])
    // Resistor selected again, then a tap on its leg end highlights the leg's net (the column it is plugged into).
    v.fingerTap(at: view(res.center))
    #expect(v.selection.ids == [res.id])
    #expect(v.netHighlight.info == nil)
    v.fingerTap(at: view(a))
    #expect(v.netHighlight.anchor == ConnectorRef(part: res.id, connector: "connector0"))
    #expect(v.netHighlight.net?.members.contains(ConnectorRef(part: board.id, connector: "pin10C")) == true)
    #expect(v.selection.ids == [res.id])
    #expect(!m.undoManager.canUndo)
}

extension CanvasView {
    /// Finger tap (pencil-only mode): the same handlers `touchesBegan`/`touchesEnded` run for a touch that does not travel.
    func fingerTap(at p: CGPoint) {
        toolState.pencilOnly = true
        let w = worldPoint(p)
        switch route(isPencil: false, at: p) {
        case .leg(let ref)?: beginLegDrag(ref, at: w); endLegDrag(at: w)
        case .move?: beginMove(at: w); endMove()
        case .pending?: handleTap(at: p)
        default: Issue.record("unexpected route")
        }
    }
}
