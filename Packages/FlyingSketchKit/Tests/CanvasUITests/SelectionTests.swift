import UIKit
import Testing
import SketchCore
@testable import CanvasUI

private func stroke(_ x: Double, _ y: Double, length: Double = 4) -> SceneObject {
    .ink(InkStroke(points: [
        InkPoint(position: Vec2(x: x, y: y), pressure: 0.5, time: 0),
        InkPoint(position: Vec2(x: x + length, y: y), pressure: 0.5, time: 0.1),
    ], tool: .pen, baseWidth: 0.5))
}

private func firstPoint(_ o: SceneObject) -> Vec2 {
    guard case .ink(let s) = o else { return .zero }
    return s.points[0].position
}

@MainActor private func canvas(_ objects: [SceneObject], assets: [String: Data] = [:]) -> (CanvasView, DocumentModel) {
    let m = DocumentModel(document: SketchDocument(objects: objects, assets: assets))
    let v = CanvasView(model: m)
    v.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
    v.layoutIfNeeded()
    return (v, m)
}

@Test @MainActor func moveIsSingleUndo() {
    let objs = [stroke(0, 0), stroke(0, 10), stroke(0, 20)]
    let (v, m) = canvas(objs)
    v.selection.ids = [objs[0].id, objs[1].id]
    v.beginMove(at: Vec2(x: 1, y: 0))
    for i in 1...20 { v.updateMove(to: Vec2(x: 1 + Double(i) * 0.5, y: 0)) }
    #expect(m.document.objects[0] == objs[0]) // visual only until release
    v.endMove()
    #expect(abs(firstPoint(m.document.objects[0]).x - 10) < 1e-9)
    #expect(abs(firstPoint(m.document.objects[1]).x - 10) < 1e-9)
    #expect(m.document.objects[2] == objs[2])
    #expect(v.selection.ids == [objs[0].id, objs[1].id])
    m.undoManager.undo()
    #expect(m.document.objects == objs)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func zeroMovePerformsNothing() {
    let objs = [stroke(0, 0)]
    let (v, m) = canvas(objs)
    v.selection.ids = [objs[0].id]
    v.beginMove(at: Vec2(x: 1, y: 0))
    v.updateMove(to: Vec2(x: 1, y: 0))
    v.endMove()
    #expect(!m.undoManager.canUndo)
    #expect(m.document.objects == objs)
}

@Test @MainActor func duplicateGetsNewIDsAndOffset() {
    let objs = [stroke(0, 0), stroke(0, 10)]
    let (v, m) = canvas(objs)
    v.selection.ids = [objs[0].id]
    v.duplicateSelection()
    #expect(m.document.objects.count == 3)
    let copy = m.document.objects[2]
    #expect(copy.id != objs[0].id && copy.id != objs[1].id)
    #expect(firstPoint(copy) == Vec2(x: 5, y: 5))
    #expect(v.selection.ids == [copy.id])
    m.undoManager.undo()
    #expect(m.document.objects == objs)
}

@Test @MainActor func deleteClearsSelectionAndEmptyDeleteDoesNothing() {
    let objs = [stroke(0, 0), stroke(0, 10)]
    let (v, m) = canvas(objs)
    v.deleteSelection()
    #expect(!m.undoManager.canUndo)
    v.selection.ids = [objs[0].id]
    v.deleteSelection()
    #expect(m.document.objects == [objs[1]])
    #expect(v.selection.ids.isEmpty)
    m.undoManager.undo()
    #expect(m.document.objects == objs)
}

@Test @MainActor func selectionDropsIDsRemovedByUndo() {
    let (v, m) = canvas([stroke(0, 0)])
    v.selection.ids = [m.document.objects[0].id]
    m.undoManager.removeAllActions()
    let extra = stroke(0, 10)
    m.perform(.insert([extra], at: nil), actionName: "Insert")
    v.selection.ids = [extra.id]
    m.undoManager.undo()
    #expect(v.selection.ids.isEmpty)
}

@Test @MainActor func lassoSelectsEnclosedObjects() {
    let objs = [stroke(0, 0), stroke(100, 100)]
    let (_, m) = canvas(objs)
    let l = LassoController(model: m)
    l.begin(at: Vec2(x: -5, y: -5))
    for p in [Vec2(x: 10, y: -5), Vec2(x: 10, y: 5), Vec2(x: -5, y: 5)] { l.move(to: p) }
    #expect(l.end() == [objs[0].id])
}

@Test @MainActor func tapSelectsObjectAndEmptyClears() {
    let objs = [stroke(0, 0)]
    let (v, _) = canvas(objs)
    let p = v.currentViewport.worldToView(Vec2(x: 2, y: 0), viewSize: v.viewSize)
    v.tap(at: CGPoint(x: p.x, y: p.y))
    #expect(v.selection.ids == [objs[0].id])
    v.tap(at: CGPoint(x: 5, y: 5))
    #expect(v.selection.ids.isEmpty)
}

@Test @MainActor func overlayFollowsSelectionBounds() {
    let objs = [stroke(0, 0)]
    let (v, _) = canvas(objs)
    v.selection.ids = [objs[0].id]
    v.updateSelectionOverlay()
    #expect(v.selectionOverlay.viewRect != nil)
    v.selection.ids = []
    v.updateSelectionOverlay()
    #expect(v.selectionOverlay.viewRect == nil)
}

@Test @MainActor func lassoToolDragInsideSelectionMoves() {
    let objs = [stroke(0, 0)]
    let (v, _) = canvas(objs)
    v.selection.ids = [objs[0].id]
    let inside = v.currentViewport.worldToView(Vec2(x: 2, y: 0), viewSize: v.viewSize)
    let p = CGPoint(x: inside.x, y: inside.y)
    for pencilOnly in [true, false] {
        v.toolState = ToolState(kind: .lasso, pencilOnly: pencilOnly)
        guard case .move? = v.route(isPencil: true, at: p) else { Issue.record("pencil should move"); return }
        guard case .lasso? = v.route(isPencil: true, at: CGPoint(x: 5, y: 5)) else { Issue.record("expected lasso"); return }
    }
    v.toolState = ToolState(kind: .lasso, pencilOnly: true)
    guard case .move? = v.route(isPencil: false, at: p) else { Issue.record("finger should move"); return }
}

@Test @MainActor func unengagedMoveInsideSelectionReselectsOrClears() {
    let a = stroke(0, 0), b = stroke(0, 1) // b overlaps a's selection bounds
    let (v, _) = canvas([a, b])
    v.selection.ids = [a.id, b.id]
    func tapInside(_ w: Vec2) {
        v.beginMove(at: w)
        v.endMove()
    }
    tapInside(Vec2(x: 2, y: 0.0)) // on a selected object: stays
    #expect(v.selection.ids == [a.id, b.id])
    tapInside(Vec2(x: 2, y: 0.5 + 100)) // far from any object but outside; selection cleared
    #expect(v.selection.ids.isEmpty)
}

@Test @MainActor func multiTouchEventIsDetected() {
    #expect(!CanvasView.isMultiTouch(nil))
}

@Suite(.serialized) @MainActor struct ClipboardTests {
    /// Private pasteboard: the general one is not authorised in the test host.
    private func clear() {
        let pb = UIPasteboard(name: UIPasteboard.Name("flysketch.tests"), create: true)!
        pb.items = []
        Clipboard.pasteboard = pb
    }

    @Test func copyPasteRoundTripsWithAssets() throws {
        clear()
        let img = SceneObject.image(ImageObject(assetName: "a.png", frame: Rect(origin: .zero, size: Vec2(x: 10, y: 10))))
        let data = Data([1, 2, 3])
        let (src, _) = canvas([img, stroke(50, 50)], assets: ["a.png": data, "unused.png": Data([9])])
        src.selection.ids = [img.id]
        src.copySelection()

        let (dst, dm) = canvas([])
        dst.viewport = Viewport(center: Vec2(x: 100, y: 200), zoom: 1)
        dst.paste()
        guard case .image(let pasted) = dm.document.objects[0] else { Issue.record("not image"); return }
        #expect(pasted.id != (img.id))
        #expect(pasted.assetName == "a.png")
        #expect(dm.document.assets == ["a.png": data]) // unreferenced asset not copied
        #expect(pasted.frame.origin == Vec2(x: 95, y: 195)) // centred on viewport centre
        #expect(dst.selection.ids == [pasted.id])
        dm.undoManager.undo()
        #expect(dm.document.objects.isEmpty)
    }

    @Test func pasteDoesNotOverwriteDifferentAssetOfSameName() throws {
        clear()
        let img = SceneObject.image(ImageObject(assetName: "a.png", frame: Rect(origin: .zero, size: Vec2(x: 10, y: 10))))
        let (src, _) = canvas([img], assets: ["a.png": Data([1])])
        src.selection.ids = [img.id]
        src.copySelection()

        let (dst, dm) = canvas([], assets: ["a.png": Data([2])])
        dst.paste()
        try #require(!dm.document.objects.isEmpty)
        guard case .image(let pasted) = dm.document.objects[0] else { Issue.record("not image"); return }
        #expect(pasted.assetName != "a.png" && pasted.assetName.hasSuffix(".png"))
        #expect(dm.document.assets["a.png"] == Data([2]))
        #expect(dm.document.assets[pasted.assetName] == Data([1]))
    }

    @Test func pasteWithEmptyClipboardPerformsNothing() {
        clear()
        let (v, m) = canvas([])
        v.paste()
        #expect(!m.undoManager.canUndo)
        #expect(m.document.objects.isEmpty)
    }
}
