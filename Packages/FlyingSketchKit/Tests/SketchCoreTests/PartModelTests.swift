import Foundation
import Testing
@testable import SketchCore

@Test func partAndWireRoundTrip() throws {
    let doc = SketchDocument.fixtureWithPartsAndWire()
    let back = try DocumentPackage.read(DocumentPackage.fileWrapper(for: doc))
    #expect(back == doc)
    #expect(back.parts.count == 2)
}

@Test func readsV1WritesV3() throws {
    func wrapper(_ json: String) -> FileWrapper {
        FileWrapper(directoryWithFileWrappers: ["document.json": FileWrapper(regularFileWithContents: Data(json.utf8))])
    }
    let v1 = #"{"formatVersion":1,"objects":[],"viewport":{"center":{"x":0,"y":0},"zoom":1}}"#
    let doc = try DocumentPackage.read(wrapper(v1))
    #expect(doc.parts.isEmpty)
    let written = try DocumentPackage.fileWrapper(for: doc)
    let json = String(decoding: written.fileWrappers!["document.json"]!.regularFileContents!, as: UTF8.self)
    #expect(json.contains(#""formatVersion":3"#))
    #expect(throws: DocumentError.unsupportedVersion(4)) { try DocumentPackage.read(wrapper(#"{"formatVersion":4,"objects":[]}"#)) }
}

@MainActor @Test func setDefinitionsUndo() {
    let model = DocumentModel(document: .empty)
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    let a = PartDefinition.fixtureResistor(), b = PartDefinition.fixtureModule()
    undo.beginUndoGrouping()
    model.perform(.setDefinitions([a.key: a, b.key: b]), actionName: "Add")
    undo.endUndoGrouping()
    #expect(model.document.parts.count == 2)
    undo.beginUndoGrouping()
    model.perform(.setDefinitions([a.key: .none]), actionName: "Remove")
    undo.endUndoGrouping()
    #expect(model.document.parts.keys.sorted() == [b.key])
    undo.undo()
    #expect(model.document.parts.count == 2)
    undo.undo()
    #expect(model.document.parts.isEmpty)
    undo.redo()
    #expect(model.document.parts.count == 2)
}

@MainActor @Test func identicalDefinitionsAreNoOp() {
    let model = DocumentModel(document: .empty)
    let a = PartDefinition.fixtureResistor()
    model.perform(.setDefinitions([a.key: a]), actionName: "Add")
    var fired = 0
    model.onChange = { _ in fired += 1 }
    model.perform(.setDefinitions([a.key: a]), actionName: "Add")
    #expect(fired == 0)
}

@Test func translatedMovesLegEndsAndWireEnds() {
    let d = Vec2(x: 3, y: -2)
    let doc = SketchDocument.fixtureWithPartsAndWire()
    guard case .part(let p) = doc.objects[0].translated(by: d),
          case .part(let p0) = doc.objects[0],
          case .wire(let w) = doc.objects[2].translated(by: d),
          case .wire(let w0) = doc.objects[2] else { Issue.record("kinds"); return }
    #expect(p.center == p0.center + d)
    #expect(p.legEnds["a"] == p0.legEnds["a"]! + d)
    #expect(w.start.position == w0.start.position + d && w.end.position == w0.end.position + d)
    #expect(w.bends == w0.bends.map { $0 + d })
    #expect(w.start.attachment == w0.start.attachment)
}

@Test func wireHitTest() {
    let wire = SceneObject.wire(Wire(start: WireEnd(position: .zero), end: WireEnd(position: Vec2(x: 10, y: 10)),
                                     bends: [Vec2(x: 10, y: 0)], width: 0.65))
    #expect(hitTest(wire, point: Vec2(x: 10.3, y: 5), tolerance: 0))
    #expect(!hitTest(wire, point: Vec2(x: 11, y: 5), tolerance: 0))
}

@Test func partGeometryUsesDefinitionAndRotation() {
    let doc = SketchDocument.fixtureWithPartsAndWire()
    let board = doc.objects[1]   // 12.7 x 15.24, one quarter turn at (40, 0)
    let r = bounds(of: board, in: doc)
    #expect(abs(r.size.x - 15.24) < 1e-9 && abs(r.size.y - 12.7) < 1e-9)
    #expect(hitTest(board, point: Vec2(x: 47, y: 5), tolerance: 0, in: doc))
    #expect(!hitTest(board, point: Vec2(x: 47, y: 7), tolerance: 0, in: doc))
    // legs included in bounds: resistor leg end at x = -7
    #expect(bounds(of: doc.objects[0], in: doc).minX <= -7)
    // doc-less fallback: 10 mm square
    #expect(bounds(of: board).size == Vec2(x: 10, y: 10))
    #expect(lassoContains([Vec2(x: 30, y: -10), Vec2(x: 50, y: -10), Vec2(x: 50, y: 10), Vec2(x: 30, y: 10)],
                          object: board, in: doc))
}

@Test func validationRejectsAbsurdPartCoordinates() throws {
    var doc = SketchDocument.fixtureWithPartsAndWire()
    guard case .part(var p) = doc.objects[0] else { return }
    p.center = Vec2(x: 1e9, y: 0)
    doc.objects[0] = .part(p)
    let w = try DocumentPackage.fileWrapper(for: doc)
    #expect(throws: DocumentError.self) { try DocumentPackage.read(w) }
}
