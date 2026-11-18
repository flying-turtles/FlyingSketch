import Foundation
import Testing
@testable import SketchCore

private let resistorDef = PartDefinition.fixtureResistor()
private let boardDef = PartDefinition.fixtureBreadboardMini()
private let moduleDef = PartDefinition.fixtureModule()

private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool { a.distance(to: b) <= tol }

private func hole(_ board: PartInstance, _ id: String) -> Vec2 { connectorPositions(board, boardDef)[id]! }

private func baseDoc(_ objects: [SceneObject]) -> SketchDocument {
    SketchDocument(objects: objects, parts: [resistorDef.key: resistorDef, boardDef.key: boardDef, moduleDef.key: moduleDef])
}

private func part(_ o: SceneObject) -> PartInstance { if case .part(let p) = o { p } else { fatalError() } }
private func wire(_ o: SceneObject) -> Wire { if case .wire(let w) = o { w } else { fatalError() } }

@Test func connectorPositionsRotate() {
    var r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 10, y: 20))
    let p0 = connectorPositions(r, resistorDef)
    // a leg default end local (-3, 1.25) -> rel (-8.08, 0)
    #expect(near(p0["a"]!, Vec2(x: 10 - 8.08, y: 20)))
    r.quarterTurns = 1
    let p1 = connectorPositions(r, resistorDef)
    #expect(near(p1["a"]!, Vec2(x: 10, y: 20 - 8.08)))
    #expect(near(p1["b"]!, Vec2(x: 10, y: 20 + 8.08)))
    // Explicit leg end wins over default.
    r.legEnds["a"] = Vec2(x: 1, y: 2)
    #expect(connectorPositions(r, resistorDef)["a"] == Vec2(x: 1, y: 2))
}

private func pluggedFixture() -> (doc: SketchDocument, board: PartInstance, resistor: PartInstance) {
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    var r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 40, y: -30))
    r.legEnds = ["a": hole(board, "c0r2"), "b": hole(board, "c2r2")]
    return (baseDoc([.part(board), .part(r)]), board, r)
}

@Test func pluggedResistorMakesTwoContacts() {
    let (doc, board, r) = pluggedFixture()
    let c = contacts(in: doc)
    #expect(c == [
        Contact(male: ConnectorRef(part: r.id, connector: "a"), female: ConnectorRef(part: board.id, connector: "c0r2")),
        Contact(male: ConnectorRef(part: r.id, connector: "b"), female: ConnectorRef(part: board.id, connector: "c2r2")),
    ])
    var off = doc
    off.objects[1] = .part({ var q = r; q.legEnds["a"] = hole(board, "c0r2") + Vec2(x: 0.3, y: 0); return q }())
    #expect(contacts(in: off).count == 1)
}

@Test func snapOffsetWithinRadius() {
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    let target = hole(board, "c1r1")
    var r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 0, y: 0))
    r.legEnds = ["a": target + Vec2(x: 0.7, y: 0), "b": Vec2(x: 200, y: 200)]
    let doc = baseDoc([.part(board)])
    let off = plugSnapOffset(for: r, in: doc, excluding: [])
    #expect(off != nil && near(off!, Vec2(x: -0.7, y: 0)))
    var far = r
    far.legEnds["a"] = target + Vec2(x: 1.3, y: 0)
    // 1.3 mm from c1r1 but 1.24 mm from c2r1: still out of range.
    #expect(plugSnapOffset(for: far, in: doc, excluding: []) == nil)
    #expect(plugSnapOffset(for: r, in: doc, excluding: [board.id]) == nil)
}

private func carryFixture() -> (doc: SketchDocument, board: PartInstance, module: PartInstance, attached: Wire, free: Wire) {
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    var module = PartInstance(definitionKey: moduleDef.key, center: .zero)
    let vccLocal = moduleDef.connectors[0].position - moduleDef.size / 2
    module.center = hole(board, "c0r0") - vccLocal
    let vcc = connectorPositions(module, moduleDef)["VCC"]!
    let attached = Wire(start: WireEnd(position: vcc, attachment: .connector(part: module.id, connector: "VCC")),
                        end: WireEnd(position: Vec2(x: 100, y: 100)), bends: [Vec2(x: 100, y: 0)])
    let free = Wire(start: WireEnd(position: Vec2(x: 90, y: 90)), end: WireEnd(position: Vec2(x: 95, y: 95)))
    return (baseDoc([.part(board), .part(module), .wire(attached), .wire(free)]), board, module, attached, free)
}

@MainActor @Test func carryAlongIsTransitiveAndOneEdit() {
    let (doc, board, module, attached, free) = carryFixture()
    #expect(contacts(in: doc).count == 4)
    let carried = carriedParts(by: [board.id], in: doc)
    #expect(carried == [module.id])
    #expect(carriedParts(by: [module.id], in: doc).isEmpty)

    let model = DocumentModel(document: doc)
    let delta = Vec2(x: 10, y: 0)
    let replaced = moveParts(carried.union([board.id]), by: delta, in: doc)
    model.perform(.replace(replaced), actionName: "Move")
    let after = model.document
    #expect(near(part(after.objects[0]).center, board.center + delta))
    #expect(near(part(after.objects[1]).center, module.center + delta))
    let w = wire(after.objects[2])
    #expect(near(w.start.position, attached.start.position + delta))
    #expect(w.end.position == attached.end.position && w.bends == attached.bends)
    #expect(wire(after.objects[3]) == free)
    #expect(contacts(in: after).count == 4)
    model.undoManager.undo()
    #expect(model.document == doc)
}

@Test func transitiveCarryAcrossTwoLevels() {
    // board <- stacker (male m0 into board, female f0 on top) <- module (VCC into f0).
    let stackerDef = PartDefinition(
        libraryID: "stacker", versionHash: "v1", title: "Stacker", size: Vec2(x: 5, y: 8), graphicAsset: "s.svg",
        graphicKind: .svg,
        connectors: [ConnectorDef(id: "f0", name: "f0", kind: .female, position: Vec2(x: 2.5, y: 1)),
                     ConnectorDef(id: "m0", name: "m0", kind: .male, position: Vec2(x: 2.5, y: 6))])
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    var stacker = PartInstance(definitionKey: stackerDef.key, center: .zero)
    stacker.center = hole(board, "c1r1") - (stackerDef.connectors[1].position - stackerDef.size / 2)
    var module = PartInstance(definitionKey: moduleDef.key, center: .zero)
    module.center = connectorPositions(stacker, stackerDef)["f0"]! - (moduleDef.connectors[0].position - moduleDef.size / 2)
    let loose = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 200, y: 0))
    var doc = baseDoc([.part(board), .part(stacker), .part(module), .part(loose)])
    doc.parts[stackerDef.key] = stackerDef
    #expect(carriedParts(by: [board.id], in: doc) == [stacker.id, module.id])
    #expect(carriedParts(by: [stacker.id], in: doc) == [module.id])
    #expect(carriedParts(by: [loose.id], in: doc).isEmpty)
}

@Test func legEndStaysWhenPlugged() {
    var (doc, board, r) = pluggedFixture()
    // Free b so only a is plugged.
    r.legEnds["b"] = nil
    doc.objects[1] = .part(r)
    let aBefore = connectorPositions(r, resistorDef)["a"]!
    let bBefore = connectorPositions(r, resistorDef)["b"]!
    let replaced = moveParts([r.id], by: Vec2(x: 5, y: -3), in: doc)
    let moved = part(replaced[0])
    let pos = connectorPositions(moved, resistorDef)
    #expect(near(pos["a"]!, aBefore))
    #expect(near(pos["b"]!, bBefore + Vec2(x: 5, y: -3)))
    #expect(near(moved.center, r.center + Vec2(x: 5, y: -3)))
    // Moving the board along with it carries the plugged leg end too.
    let both = moveParts([r.id, board.id], by: Vec2(x: 5, y: 0), in: doc)
    let movedBoth = both.compactMap { o -> PartInstance? in if case .part(let p) = o, p.id == r.id { p } else { nil } }[0]
    #expect(near(connectorPositions(movedBoth, resistorDef)["a"]!, aBefore + Vec2(x: 5, y: 0)))
}

@Test func rotatePartResetsLegsAndUpdatesWires() {
    let r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 0, y: 0), legEnds: ["a": Vec2(x: -7, y: 3)])
    let w = Wire(start: WireEnd(position: Vec2(x: -7, y: 3), attachment: .connector(part: r.id, connector: "a")),
                 end: WireEnd(position: Vec2(x: 30, y: 5)))
    let doc = baseDoc([.part(r), .wire(w)])
    let out = rotatePart(r.id, clockwise: true, in: doc)
    #expect(out.count == 2)
    let rotated = part(out[0])
    #expect(rotated.quarterTurns == 1 && rotated.legEnds.isEmpty)
    #expect(near(wire(out[1]).start.position, connectorPositions(rotated, resistorDef)["a"]!))
    #expect(part(rotatePart(r.id, clockwise: false, in: doc)[0]).quarterTurns == 3)
}

@MainActor @Test func deletingPartDetachesWiresInOneEdit() {
    let r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 0, y: 0))
    let w = Wire(start: WireEnd(position: Vec2(x: 5, y: 0), attachment: .connector(part: r.id, connector: "b")),
                 end: WireEnd(position: Vec2(x: 30, y: 5)))
    let doc = baseDoc([.part(r), .wire(w)])
    let model = DocumentModel(document: doc)
    var changes = 0
    model.onChange = { _ in changes += 1 }
    let (removed, detached) = removeParts([r.id], in: doc)
    #expect(removed == [r.id])
    model.perform([.replace(detached), .remove(removed)], actionName: "Delete")
    #expect(changes == 1)
    #expect(model.document.objects.count == 1)
    let left = wire(model.document.objects[0])
    #expect(left.start.attachment == nil && left.start.position == w.start.position)
    model.undoManager.undo()
    #expect(model.document == doc)
    model.undoManager.redo()
    #expect(model.document.objects.count == 1 && wire(model.document.objects[0]).start.attachment == nil)
}

@MainActor @Test func batchPerformSkipsNoOps() {
    let doc = baseDoc([])
    let model = DocumentModel(document: doc)
    var changes = 0
    model.onChange = { _ in changes += 1 }
    model.perform([.remove([ObjectID.new()]), .replace([])], actionName: "Nothing")
    #expect(changes == 0 && !model.undoManager.canUndo)
}

@Test func reconcileWiresFollowsAndClears() {
    var r = PartInstance(definitionKey: resistorDef.key, center: Vec2(x: 0, y: 0))
    let w = Wire(start: WireEnd(position: Vec2(x: 99, y: 99), attachment: .connector(part: r.id, connector: "b")),
                 end: WireEnd(position: Vec2(x: 1, y: 1), attachment: .connector(part: r.id, connector: "gone")))
    let doc = baseDoc([.part(r), .wire(w)])
    let out = reconcileWires(in: doc)
    #expect(out.count == 1)
    let fixed = wire(out[0])
    #expect(near(fixed.start.position, connectorPositions(r, resistorDef)["b"]!))
    #expect(fixed.end.attachment == nil && fixed.end.position == Vec2(x: 1, y: 1))
    r.center = .zero
    #expect(reconcileWires(in: baseDoc([.part(r), .wire(fixed)])).isEmpty)
}

@Test func snapTieIsDeterministicFirstConnectorWins() {
    // Legs +-0.46 from nearest holes in the same column: equal-length offsets with opposite signs.
    let board = PartInstance(definitionKey: boardDef.key, center: Vec2(x: 40, y: 0))
    let h = hole(board, "c1r0")
    var r = PartInstance(definitionKey: resistorDef.key, center: .zero)
    r.legEnds = ["a": h + Vec2(x: 0, y: 0.46), "b": hole(board, "c1r3") + Vec2(x: 0, y: -0.46)]
    let doc = baseDoc([.part(board)])
    for _ in 0..<20 {
        let off = plugSnapOffset(for: r, in: doc, excluding: [])
        #expect(off != nil && near(off!, Vec2(x: 0, y: -0.46)))
    }
}

@Test func wireOnPinnedLegStaysAndDefaultEndPins() {
    var (doc, board, r) = pluggedFixture()
    // a: plugged with a default (not materialised) end; b free.
    r.legEnds = [:]
    r.center = hole(board, "c0r2") - (resistorDef.connectors[0].leg!.defaultEnd - resistorDef.size / 2)
    let aPos = connectorPositions(r, resistorDef)["a"]!
    let bPos = connectorPositions(r, resistorDef)["b"]!
    let w = Wire(start: WireEnd(position: aPos, attachment: .connector(part: r.id, connector: "a")),
                 end: WireEnd(position: Vec2(x: 90, y: 90)))
    let w2 = Wire(start: WireEnd(position: bPos, attachment: .connector(part: r.id, connector: "b")),
                  end: WireEnd(position: Vec2(x: 90, y: 91)))
    doc.objects = [.part(board), .part(r), .wire(w), .wire(w2)]
    let d = Vec2(x: 3, y: -4)
    let out = moveParts([r.id], by: d, in: doc)
    let moved = part(out[0])
    #expect(near(connectorPositions(moved, resistorDef)["a"]!, aPos))
    #expect(moved.legEnds["a"] != nil && moved.legEnds["b"] == nil)
    // Wire on pinned leg is unchanged -> not returned; wire on free leg follows.
    #expect(out.count == 2)
    #expect(wire(out[1]).id == w2.id && near(wire(out[1]).start.position, bPos + d))
}

@MainActor @Test func mixedBatchUndoRedoUndoRoundTrip() {
    let r = PartInstance(definitionKey: resistorDef.key, center: .zero)
    let w = Wire(start: WireEnd(position: Vec2(x: 5, y: 0), attachment: .connector(part: r.id, connector: "b")),
                 end: WireEnd(position: Vec2(x: 30, y: 5)))
    let doc = baseDoc([.part(r), .wire(w)])
    let model = DocumentModel(document: doc)
    let (removed, detached) = removeParts([r.id], in: doc)
    model.perform([.replace(detached), .remove(removed)], actionName: "Delete")
    let after = model.document
    model.undoManager.undo()
    #expect(model.document == doc)
    model.undoManager.redo()
    #expect(model.document == after)
    model.undoManager.undo()
    #expect(model.document == doc)
}

@Test func rigidMoveUnplugsLegs() {
    let (doc, _, r) = pluggedFixture()
    let d = Vec2(x: 0, y: -10)
    let pinned = part(moveParts([r.id], by: d, in: doc).first { $0.id == r.id }!)
    #expect(pinned.legEnds == r.legEnds)
    let rigid = part(moveParts([r.id], by: d, in: doc, rigid: [r.id]).first { $0.id == r.id }!)
    #expect(near(rigid.legEnds["a"]!, r.legEnds["a"]! + d))
    #expect(near(rigid.legEnds["b"]!, r.legEnds["b"]! + d))
    #expect(near(rigid.center, r.center + d))
}
