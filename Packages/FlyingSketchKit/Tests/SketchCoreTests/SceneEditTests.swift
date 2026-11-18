import Foundation
import Testing
@testable import SketchCore

private func stroke(_ x: Double = 0) -> InkStroke {
    InkStroke(points: [InkPoint(position: Vec2(x: x, y: 0), pressure: 0.5, time: 0)])
}

private func ids(_ doc: SketchDocument) -> [ObjectID] { doc.objects.map(\.id) }

@Test func removeThenUndoRestoresOrder() {
    var doc = SketchDocument.fixtureThreeStrokes()
    let (a, b, c) = (doc.objects[0], doc.objects[1], doc.objects[2])
    let inverse = SceneEdit.remove([b.id]).apply(to: &doc)
    #expect(ids(doc) == [a.id, c.id])
    _ = inverse.apply(to: &doc)
    #expect(ids(doc) == [a.id, b.id, c.id])
}

@Test func removeNonAdjacentRestoresIndices() {
    var doc = SketchDocument(objects: (0..<5).map { .ink(stroke(Double($0))) })
    let original = doc
    let inverse = SceneEdit.remove([original.objects[1].id, original.objects[3].id]).apply(to: &doc)
    #expect(ids(doc) == [original.objects[0].id, original.objects[2].id, original.objects[4].id])
    let redo = inverse.apply(to: &doc)
    #expect(doc == original)
    _ = redo.apply(to: &doc)
    #expect(doc.objects.count == 3)
}

@Test func insertAtIndexAndTop() {
    var doc = SketchDocument.fixtureThreeStrokes()
    let ids0 = ids(doc)
    let x = SceneObject.ink(stroke(9)), y = SceneObject.ink(stroke(10))
    let inv1 = SceneEdit.insert([x], at: 1).apply(to: &doc)
    #expect(ids(doc) == [ids0[0], x.id, ids0[1], ids0[2]])
    let inv2 = SceneEdit.insert([y], at: nil).apply(to: &doc)
    #expect(ids(doc).last == y.id)
    _ = inv2.apply(to: &doc)
    _ = inv1.apply(to: &doc)
    #expect(ids(doc) == ids0)
}

@Test func insertIndexIsClamped() {
    var doc = SketchDocument.fixtureThreeStrokes()
    let x = SceneObject.ink(stroke(9))
    _ = SceneEdit.insert([x], at: 99).apply(to: &doc)
    #expect(doc.objects.last?.id == x.id)
}

@Test func replaceKeepsPositionAndInverts() {
    var doc = SketchDocument.fixtureThreeStrokes()
    let original = doc
    let moved = doc.objects[1].translated(by: Vec2(x: 5, y: 5))
    let inverse = SceneEdit.replace([moved]).apply(to: &doc)
    #expect(doc.objects[1] == moved)
    #expect(ids(doc) == ids(original))
    _ = inverse.apply(to: &doc)
    #expect(doc == original)
}

@MainActor @Test func undoRedoThroughModel() {
    let m = DocumentModel(document: .empty)
    m.perform(.insert([.ink(stroke())], at: nil), actionName: "Draw")
    #expect(m.document.objects.count == 1)
    m.undoManager.undo(); #expect(m.document.objects.isEmpty)
    m.undoManager.redo(); #expect(m.document.objects.count == 1)
    m.undoManager.undo(); #expect(m.document.objects.isEmpty)
    m.undoManager.redo(); #expect(m.document.objects.count == 1)
}

@MainActor @Test func actionNameAndOnChange() {
    let m = DocumentModel(document: .empty)
    var calls: [Int] = []
    m.onChange = { calls.append($0.objects.count) }
    m.perform(.insert([.ink(stroke())], at: nil), actionName: "Draw")
    #expect(m.undoManager.undoActionName == "Draw")
    m.undoManager.undo()
    m.undoManager.redo()
    #expect(calls == [1, 0, 1])
}

@MainActor @Test func usesCurrentUndoManager() {
    let m = DocumentModel(document: .empty)
    let injected = UndoManager()
    m.undoManager = injected
    m.perform(.insert([.ink(stroke())], at: nil), actionName: "Draw")
    #expect(injected.canUndo)
    injected.undo()
    #expect(m.document.objects.isEmpty)
}
