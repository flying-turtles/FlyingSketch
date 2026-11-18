import UIKit
import Testing
import SketchCore
import InkEngine
@testable import CanvasUI

private let existing = TextObject(text: "Hello", position: Vec2(x: 0, y: 0), fontSize: 5)

@MainActor private func canvas() -> (CanvasView, DocumentModel, CGPoint) {
    let m = DocumentModel(document: SketchDocument(objects: [.text(existing)]))
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    let p = v.currentViewport.worldToView(Vec2(x: 2, y: 2), viewSize: v.viewSize)
    return (v, m, CGPoint(x: p.x, y: p.y))
}

@MainActor private func currentText(_ m: DocumentModel) -> TextObject? {
    for case .text(let t) in m.document.objects where t.id == existing.id { return t }
    return nil
}

@Test @MainActor func editHidesLayerThenCommitRestoresIt() {
    let (v, m, p) = canvas()
    v.beginTextEditing(at: p)
    #expect(v.textSession?.existing?.id == existing.id)
    #expect(v.renderer.hiddenIDs == [existing.id])
    v.textSession?.view.text = "Bye"
    v.endTextEditing()
    #expect(v.renderer.hiddenIDs.isEmpty)
    #expect(currentText(m)?.text == "Bye")
    #expect(m.undoManager.undoActionName == "Edit Text")
}

@Test @MainActor func toolChangeCommitsAndRestores() {
    let (v, m, p) = canvas()
    v.toolState.kind = .text
    v.beginTextEditing(at: p)
    v.textSession?.view.text = "Changed"
    v.toolState.kind = .ink(.pen)
    #expect(v.textSession == nil)
    #expect(v.renderer.hiddenIDs.isEmpty)
    #expect(currentText(m)?.text == "Changed")
}

@Test @MainActor func editingToEmptyRemoves() {
    let (v, m, p) = canvas()
    v.beginTextEditing(at: p)
    v.textSession?.view.text = "  "
    v.endTextEditing()
    #expect(currentText(m) == nil)
    #expect(m.undoManager.undoActionName == "Delete Text")
}

@Test @MainActor func newTextInEmptySpaceCommitsOnEnd() {
    let (v, m, _) = canvas()
    v.beginTextEditing(at: CGPoint(x: 900, y: 1200))
    #expect(v.textSession?.existing == nil)
    v.textSession?.view.text = "New"
    v.endTextEditing()
    #expect(m.document.objects.count == 2)
    #expect(m.undoManager.undoActionName == "Add Text")
}

@Test @MainActor func removedMidEditEndsSessionAndCommitsNothing() {
    let (v, m, p) = canvas()
    v.beginTextEditing(at: p)
    v.textSession?.view.text = "Edited"
    m.perform(.remove([existing.id]), actionName: "Remove")
    #expect(v.textSession == nil)
    #expect(m.document.objects.isEmpty)
    #expect(m.undoManager.undoActionName == "Remove")
}

@Test @MainActor func staleCommitKeepsExternalChange() {
    let m = DocumentModel(document: SketchDocument(objects: [.text(existing)]))
    let t = TextController(model: m)
    m.perform(.replace([.text(TextObject(id: existing.id, text: "Hello", position: Vec2(x: 50, y: 50)))]), actionName: "Move")
    #expect(t.commit("Typed", existing: existing, position: .zero, fontSize: 5, color: .black))
    #expect(currentText(m)?.position == Vec2(x: 50, y: 50))
    #expect(currentText(m)?.text == "Typed")
    // gone: skipped
    m.perform(.remove([existing.id]), actionName: "Remove")
    #expect(!t.commit("Again", existing: existing, position: .zero, fontSize: 5, color: .black))
    #expect(!t.commit("", existing: existing, position: .zero, fontSize: 5, color: .black))
    #expect(m.undoManager.undoActionName == "Remove")
}

@Test @MainActor func textToolDragIsNotATap() {
    let (v, _, p) = canvas()
    v.toolState.kind = .text
    guard case .text? = v.route(isPencil: true, at: p) else { Issue.record("text route"); return }
    #expect(CanvasView.textTapSlop == 4)
}
