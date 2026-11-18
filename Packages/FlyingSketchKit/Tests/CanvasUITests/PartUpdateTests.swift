import UIKit
import Testing
import SketchCore
import PartsKit
@testable import CanvasUI

private let oldDef = PartDefinition.fixtureResistor()
private let boardDef = PartDefinition.fixtureBreadboardMini()
private let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"2.5mm\"/>".utf8)

/// v2 of the resistor: connector `a` moved 1 mm, `b` removed, `c` added.
private func newResistor(hash: String = "v2") -> PartDefinition {
    var d = oldDef
    d.versionHash = hash
    d.graphicAsset = "resistor-\(hash).svg"
    d.connectors = [
        ConnectorDef(id: "a", name: "a", kind: .male, position: Vec2(x: 1, y: 1.25),
                     leg: LegSpec(origin: Vec2(x: 1, y: 1.25), defaultEnd: Vec2(x: -3, y: 1.25), color: .black)),
        ConnectorDef(id: "c", name: "c", kind: .male, position: Vec2(x: 10, y: 1.25)),
    ]
    return d
}

private func libPart(_ d: PartDefinition) -> LibraryPart { LibraryPart(definition: d, graphic: svg, source: .bundled) }

@MainActor private func canvas(_ objects: [SceneObject]) -> (CanvasView, DocumentModel) {
    let defs = [oldDef.key: oldDef, boardDef.key: boardDef]
    let assets = [oldDef.graphicAsset: svg, boardDef.graphicAsset: svg]
    let m = DocumentModel(document: SketchDocument(objects: objects, assets: assets, parts: defs))
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    return (v, m)
}

private func part(_ o: SceneObject) -> PartInstance? { if case .part(let p) = o { p } else { nil } }
private func wire(_ o: SceneObject) -> Wire? { if case .wire(let w) = o { w } else { nil } }

@MainActor private struct Scene {
    var r1: PartInstance
    var r2: PartInstance
    var wireA: Wire
    var wireB: Wire
    var objects: [SceneObject] { [.part(r1), .part(r2), .wire(wireA), .wire(wireB)] }

    init() {
        r1 = PartInstance(definitionKey: oldDef.key, center: Vec2(x: 0, y: 0), label: "R1",
                          properties: ["resistance": "1k", "custom": "x"], legEnds: ["a": Vec2(x: -5, y: 4), "b": Vec2(x: 20, y: 4)])
        r2 = PartInstance(definitionKey: oldDef.key, center: Vec2(x: 0, y: 30), quarterTurns: 1, label: "R7")
        let pa = connectorPositions(r1, oldDef)["a"]!, pb = connectorPositions(r1, oldDef)["b"]!
        wireA = Wire(start: WireEnd(position: pa, attachment: .connector(part: r1.id, connector: "a")),
                     end: WireEnd(position: Vec2(x: 50, y: 50)))
        wireB = Wire(start: WireEnd(position: pb, attachment: .connector(part: r1.id, connector: "b")),
                     end: WireEnd(position: Vec2(x: 60, y: 50)))
    }
}

@Test @MainActor func detectsOutdatedPart() {
    let s = Scene()
    let (v, _) = canvas(s.objects + [.part(PartInstance(definitionKey: boardDef.key, center: .zero))])
    let same = libPart(oldDef)
    #expect(v.outdatedParts(comparedTo: [same, libPart(boardDef)]).isEmpty)
    let newer = libPart(newResistor())
    let found = v.outdatedParts(comparedTo: [newer, libPart(boardDef)])
    #expect(found.count == 1)
    #expect(found[0].current == oldDef && found[0].newer == newer)
    // Library without the part: nothing to update.
    #expect(v.outdatedParts(comparedTo: []).isEmpty)
}

@Test @MainActor func unreferencedDefinitionIsNotOutdated() {
    let (v, _) = canvas([])
    #expect(v.outdatedParts(comparedTo: [libPart(newResistor())]).isEmpty)
}

@Test @MainActor func updateRepointsInstancesInOneEdit() throws {
    let s = Scene()
    let (v, m) = canvas(s.objects)
    let before = m.document
    let newer = libPart(newResistor())
    v.updatePart(libraryID: oldDef.libraryID, to: newer)
    let doc = m.document
    #expect(doc.parts[oldDef.key] == nil)
    #expect(doc.parts[newer.definition.key] == newer.definition)
    #expect(doc.assets[newer.definition.graphicAsset] == svg)
    let parts = doc.objects.compactMap(part)
    #expect(parts.allSatisfy { $0.definitionKey == newer.definition.key })
    let r1 = try #require(parts.first { $0.id == s.r1.id })
    #expect(r1.label == "R1" && r1.properties == ["resistance": "1k", "custom": "x"])
    #expect(r1.legEnds == ["a": Vec2(x: -5, y: 4)])
    #expect(parts.first { $0.id == s.r2.id }?.quarterTurns == 1)
    #expect(v.outdatedParts(comparedTo: [newer]).isEmpty)

    m.undoManager.undo()
    #expect(m.document.objects == before.objects)
    #expect(m.document.parts == before.parts)
    #expect(!m.undoManager.canUndo)
    m.undoManager.redo()
    #expect(m.document.parts[oldDef.key] == nil)
}

@Test @MainActor func vanishedConnectorFreesWire() throws {
    let s = Scene()
    let (v, m) = canvas(s.objects)
    let newer = libPart(newResistor())
    v.updatePart(libraryID: oldDef.libraryID, to: newer)
    let wires = m.document.objects.compactMap(wire)
    let a = try #require(wires.first { $0.id == s.wireA.id })
    let r1 = try #require(m.document.objects.compactMap(part).first { $0.id == s.r1.id })
    #expect(a.start.attachment == .connector(part: s.r1.id, connector: "a"))
    #expect(a.start.position == connectorPositions(r1, newer.definition)["a"])
    let b = try #require(wires.first { $0.id == s.wireB.id })
    #expect(b.start.attachment == nil)
    #expect(b.start.position == s.wireB.start.position)
    m.undoManager.undo()
    #expect(m.document.objects.compactMap(wire).first { $0.id == s.wireB.id } == s.wireB)
    #expect(m.document.objects.compactMap(wire).first { $0.id == s.wireA.id } == s.wireA)
}

@Test @MainActor func updateKeepsDefinitionUsedByOtherVersion() throws {
    // Document already holds the newest version next to an old one: old instances move, new ones stay.
    let newDef = newResistor()
    let fresh = PartInstance(definitionKey: newDef.key, center: Vec2(x: 0, y: 60), label: "R2")
    var s = Scene()
    s.r2.definitionKey = oldDef.key
    let (v, m) = canvas(s.objects + [.part(fresh)])
    try m.addAssets([newDef.graphicAsset: svg])
    _ = m.perform(.setDefinitions([newDef.key: newDef]), actionName: "x")
    v.updatePart(libraryID: oldDef.libraryID, to: libPart(newDef))
    #expect(m.document.objects.compactMap(part).allSatisfy { $0.definitionKey == newDef.key })
    #expect(m.document.parts[oldDef.key] == nil)
    #expect(m.document.parts[newDef.key] == newDef)
}

@Test @MainActor func updateWithNothingOutdatedDoesNothing() {
    let (v, m) = canvas(Scene().objects)
    v.updatePart(libraryID: oldDef.libraryID, to: libPart(oldDef))
    v.updatePart(libraryID: "unknown", to: libPart(newResistor()))
    #expect(!m.undoManager.canUndo)
}

@Suite(.serialized) @MainActor struct PartUpdatePasteTests {
    @Test func pasteKeepsBothVersions() throws {
        let pb = UIPasteboard(name: UIPasteboard.Name("flysketch.partupdates.tests"), create: true)!
        pb.items = []
        Clipboard.pasteboard = pb
        let newDef = newResistor()
        let s = Scene()
        let (src, _) = canvas(s.objects)
        src.selection.ids = [s.r1.id]
        src.copySelection()
        // Target document holds v2 of the same library part.
        let target = DocumentModel(document: SketchDocument(objects: [.part(PartInstance(definitionKey: newDef.key, center: .zero, label: "R1"))],
                                                            assets: [newDef.graphicAsset: svg], parts: [newDef.key: newDef]))
        let v = CanvasView(model: target)
        v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        v.layoutIfNeeded()
        v.paste()
        #expect(target.document.parts[oldDef.key] == oldDef)
        #expect(target.document.parts[newDef.key] == newDef)
        #expect(target.document.objects.compactMap(part).map(\.definitionKey).sorted() == [newDef.key, oldDef.key].sorted())
    }
}
