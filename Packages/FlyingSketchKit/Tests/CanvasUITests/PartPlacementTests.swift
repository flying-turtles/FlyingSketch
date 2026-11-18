import UIKit
import Testing
import SketchCore
import PartsKit
@testable import CanvasUI

private let resistorDef = PartDefinition.fixtureResistor()
private let boardDef = PartDefinition.fixtureBreadboardMini()
private let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"2.5mm\"/>".utf8)

private func part(_ o: SceneObject?) -> PartInstance? { if case .part(let p)? = o { p } else { nil } }
private func wire(_ o: SceneObject?) -> Wire? { if case .wire(let w)? = o { w } else { nil } }
private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool { a.distance(to: b) <= tol }

@MainActor private func canvas(_ objects: [SceneObject], parts: [PartDefinition] = [resistorDef, boardDef])
    -> (CanvasView, DocumentModel) {
    let defs = Dictionary(uniqueKeysWithValues: parts.map { ($0.key, $0) })
    let assets = Dictionary(uniqueKeysWithValues: parts.map { ($0.graphicAsset, svg) })
    let m = DocumentModel(document: SketchDocument(objects: objects, assets: assets, parts: defs))
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    return (v, m)
}

@MainActor private func object(_ m: DocumentModel, _ id: ObjectID) -> SceneObject? {
    m.document.objects.first { $0.id == id }
}

private func hole(_ board: PartInstance, _ id: String) -> Vec2 { connectorPositions(board, boardDef)[id]! }

/// Board at (40, 0); resistor plugged into c0r2/c2r2; wire from the resistor's `b` to a free point.
private func pluggedScene() -> (objects: [SceneObject], board: PartInstance, resistor: PartInstance, wire: Wire) {
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0), label: "BB1")
    var r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 40, y: -30), label: "R1")
    r.legEnds = ["a": hole(board, "c0r2"), "b": hole(board, "c2r2")]
    let w = Wire(start: WireEnd(position: hole(board, "c2r2"), attachment: .connector(part: r.id, connector: "b")),
                 end: WireEnd(position: Vec2(x: 80, y: 40)))
    return ([.part(board), .part(r), .wire(w)], board, r, w)
}

@MainActor private func drag(_ v: CanvasView, by d: Vec2) {
    v.beginMove(at: .zero)
    v.updateMove(to: d * 0.5)
    v.updateMove(to: d)
    v.endMove()
}

@Test @MainActor func placePartEmbedsDefinitionOnce() {
    let (v, m) = canvas([], parts: [])
    let lib = LibraryPart(definition: resistorDef, graphic: svg, source: .bundled)
    // Explicit groups: by-event grouping would merge both placements (same run-loop turn) into one undo step.
    m.undoManager.groupsByEvent = false
    for _ in 0..<2 {
        m.undoManager.beginUndoGrouping()
        v.placePart(lib)
        m.undoManager.endUndoGrouping()
    }
    #expect(m.document.parts.count == 1)
    #expect(m.document.parts[resistorDef.key] == resistorDef)
    #expect(m.document.assets[resistorDef.graphicAsset] == svg)
    let labels = m.document.objects.compactMap { part($0)?.label }
    #expect(labels == ["R1", "R2"])
    #expect(v.selection.ids == [m.document.objects[1].id])
    #expect(part(m.document.objects[0])?.center == v.viewport.center)
    m.undoManager.undo()
    #expect(m.document.objects.count == 1)
    #expect(m.document.parts.count == 1)
    m.undoManager.undo()
    #expect(m.document.objects.isEmpty)
    #expect(m.document.parts.isEmpty)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func placePartWithoutPrefixHasNoLabel() {
    var def = resistorDef
    def.labelPrefix = ""
    def.properties = ["resistance": "220Ω"]
    let (v, m) = canvas([], parts: [])
    v.placePart(LibraryPart(definition: def, graphic: svg, source: .bundled))
    #expect(part(m.document.objects.first)?.label == "")
    #expect(part(m.document.objects.first)?.properties == ["resistance": "220Ω"])
}

@Test @MainActor func moveBreadboardCarriesPlugged() {
    let s = pluggedScene()
    let (v, m) = canvas(s.objects)
    let d = Vec2(x: 10, y: 0)
    v.selection.ids = [s.board.id]
    v.beginMove(at: .zero)
    v.updateMove(to: d)
    // Preview: carried resistor and attached wire are re-rendered moved.
    #expect(Set(v.renderer.previewObjects.keys).isSuperset(of: [s.resistor.id, s.wire.id]))
    v.endMove()
    #expect(v.renderer.previewObjects.isEmpty)
    let r = part(object(m, s.resistor.id))!
    #expect(near(r.center, s.resistor.center + d))
    #expect(near(r.legEnds["a"]!, s.resistor.legEnds["a"]! + d))
    #expect(near(part(object(m, s.board.id))!.center, s.board.center + d))
    let w = wire(object(m, s.wire.id))!
    #expect(near(w.start.position, s.wire.start.position + d))
    #expect(w.end == s.wire.end)
    #expect(contacts(in: m.document).count == 2)
    m.undoManager.undo()
    #expect(m.document.objects == s.objects)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func dropSnapsIntoHoles() {
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    var r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 40, y: -30), label: "R1")
    let lift = Vec2(x: 0.6, y: -20)
    r.legEnds = ["a": hole(board, "c0r2") + lift, "b": hole(board, "c2r2") + lift]
    let (v, m) = canvas([.part(board), .part(r)])
    #expect(contacts(in: m.document).isEmpty)
    v.selection.ids = [r.id]
    drag(v, by: Vec2(x: 0, y: 20))
    #expect(contacts(in: m.document).count == 2)
    let moved = part(object(m, r.id))!
    #expect(near(moved.legEnds["a"]!, hole(board, "c0r2"), 1e-6))
    m.undoManager.undo()
    #expect(part(object(m, r.id)) == r)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func deleteDetachesWires() {
    let s = pluggedScene()
    let ink = SceneObject.ink(InkStroke(points: [InkPoint(position: Vec2(x: 0, y: 50), pressure: 0.5, time: 0)],
                                        tool: .pen, baseWidth: 0.5))
    let (v, m) = canvas(s.objects + [ink])
    v.selection.ids = [s.resistor.id, ink.id]
    v.deleteSelection()
    #expect(object(m, s.resistor.id) == nil)
    #expect(object(m, ink.id) == nil)
    let w = wire(object(m, s.wire.id))!
    #expect(w.start.attachment == nil)
    #expect(w.start.position == s.wire.start.position)
    #expect(v.selection.ids.isEmpty)
    m.undoManager.undo()
    #expect(m.document.objects == s.objects + [ink])
    #expect(!m.undoManager.canUndo)
}

@Suite(.serialized) @MainActor struct PartClipboardTests {
    private func clear() {
        let pb = UIPasteboard(name: UIPasteboard.Name("flysketch.parts.tests"), create: true)!
        pb.items = []
        Clipboard.pasteboard = pb
    }

    @Test func pasteRemapsWireAttachments() throws {
        clear()
        let s = pluggedScene()
        let toBoard = Wire(start: WireEnd(position: hole(s.board, "c0r0"), attachment: .connector(part: s.board.id, connector: "c0r0")),
                           end: WireEnd(position: Vec2(x: 0, y: 60)))
        let (v, m) = canvas(s.objects + [.wire(toBoard)])
        v.selection.ids = [s.resistor.id, s.wire.id, toBoard.id]
        v.copySelection()
        v.paste()
        #expect(m.document.objects.count == 7)
        let pasted = Array(m.document.objects.suffix(3))
        let r = try #require(pasted.compactMap(part).first)
        #expect(r.id != s.resistor.id)
        #expect(r.label == "R2")
        let wires = pasted.compactMap(wire)
        let w1 = try #require(wires.first { $0.end.attachment == nil && $0.start.attachment != nil })
        #expect(w1.start.attachment == .connector(part: r.id, connector: "b"))
        #expect(wires.contains { $0.start.attachment == nil && $0.end.attachment == nil })
        #expect(v.selection.ids == Set(pasted.map(\.id)))
        m.undoManager.undo()
        #expect(m.document.objects == s.objects + [.wire(toBoard)])
    }

    @Test func pasteCarriesDefinitionsIntoOtherDocument() throws {
        clear()
        let s = pluggedScene()
        let (src, _) = canvas(s.objects)
        src.selection.ids = [s.resistor.id]
        src.copySelection()
        let (dst, dm) = canvas([], parts: [])
        dst.paste()
        #expect(dm.document.parts == [resistorDef.key: resistorDef])
        #expect(dm.document.assets[resistorDef.graphicAsset] == svg)
        #expect(part(dm.document.objects.first)?.label == "R1")
        dm.undoManager.undo()
        #expect(dm.document.parts.isEmpty)
        #expect(dm.document.objects.isEmpty)
    }

    @Test func oldPayloadWithoutDefinitionsDecodes() throws {
        clear()
        let ink = SceneObject.ink(InkStroke(points: [InkPoint(position: .zero, pressure: 0.5, time: 0)],
                                            tool: .pen, baseWidth: 0.5))
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(["objects": [ink]]))
        var dict = old as! [String: Any]
        dict["assets"] = [String: String]()
        Clipboard.pasteboard.setItems([[Clipboard.typeIdentifier: try JSONSerialization.data(withJSONObject: dict)]])
        let clip = try #require(Clipboard.read())
        #expect(clip.objects.count == 1)
        #expect(clip.definitions.isEmpty)
    }
}

@Test @MainActor func duplicateRenumbersLabelsAndRemaps() throws {
    let s = pluggedScene()
    let (v, m) = canvas(s.objects)
    v.selection.ids = [s.resistor.id, s.wire.id]
    v.duplicateSelection()
    let copies = m.document.objects.suffix(2)
    let r = try #require(copies.compactMap(part).first)
    #expect(r.label == "R2")
    #expect(r.definitionKey == resistorDef.key)
    #expect(copies.compactMap(wire).first?.start.attachment == .connector(part: r.id, connector: "b"))
}

@Test @MainActor func rotateUpdatesAttachedWireEnds() {
    let s = pluggedScene()
    let (v, m) = canvas(s.objects)
    v.selection.ids = [s.resistor.id]
    v.rotateSelectedParts(clockwise: true)
    let r = part(object(m, s.resistor.id))!
    #expect(r.quarterTurns == 1)
    let w = wire(object(m, s.wire.id))!
    #expect(near(w.start.position, connectorPositions(r, resistorDef)["b"]!))
    #expect(m.undoManager.undoActionName == "Rotate")
    m.undoManager.undo()
    #expect(m.document.objects == s.objects)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func updatePartPropertiesIsOneEditAndSkipsNoOp() {
    let s = pluggedScene()
    let (v, m) = canvas(s.objects)
    v.updatePartProperties(s.resistor.id, label: "R1", properties: [:])
    #expect(!m.undoManager.canUndo)
    v.updatePartProperties(s.resistor.id, label: "R9", properties: ["resistance": "1k"])
    let r = part(object(m, s.resistor.id))!
    #expect(r.label == "R9" && r.properties == ["resistance": "1k"])
    #expect(m.undoManager.undoActionName == "Edit Part")
}

@Test @MainActor func nextLabelUsesLowestFreeNumber() {
    let labels = ["R1", "R3", "Rx", "RA2", "U1"]
    #expect(nextPartLabel(prefix: "R", existing: labels) == "R2")
    #expect(nextPartLabel(prefix: "U", existing: labels) == "U2")
    #expect(nextPartLabel(prefix: "C", existing: labels) == "C1")
    #expect(nextPartLabel(prefix: "", existing: labels) == "")
}

@Test @MainActor func tapHitsPartBodyOutsideFallbackSquare() {
    let board = PartInstance(definitionKey: boardDef.key, center: .zero)
    // 12.7 x 15.24 mm board; (0, 7) lies outside the 10 mm fallback square but inside the body.
    let (v, _) = canvas([.part(board)])
    let p = v.currentViewport.worldToView(Vec2(x: 0, y: 7), viewSize: v.viewSize)
    v.tap(at: CGPoint(x: p.x, y: p.y))
    #expect(v.selection.ids == [board.id])
}
