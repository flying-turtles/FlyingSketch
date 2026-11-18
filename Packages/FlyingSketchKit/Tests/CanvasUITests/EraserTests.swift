import Testing
import SketchCore
@testable import CanvasUI

private func stroke(_ x: Double, _ y: Double, length: Double = 4) -> SceneObject {
    .ink(InkStroke(points: [
        InkPoint(position: Vec2(x: x, y: y), pressure: 0.5, time: 0),
        InkPoint(position: Vec2(x: x + length, y: y), pressure: 0.5, time: 0.1),
    ], tool: .pen, baseWidth: 0.5))
}

@Test @MainActor func eraseGestureIsSingleUndo() {
    let objects = [stroke(0, 0), stroke(0, 20), stroke(0, 40)]
    let m = DocumentModel(document: SketchDocument(objects: objects))
    let e = EraserController(model: m)
    e.begin(at: Vec2(x: 1, y: 0), radius: 1)
    for y in stride(from: 1.0, through: 20.0, by: 1) { e.move(to: Vec2(x: 1, y: y)) }
    e.end()
    #expect(m.document.objects == [objects[2]])
    m.undoManager.undo()
    #expect(m.document.objects == objects)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func eraseHittingNothingPerformsNothing() {
    let m = DocumentModel(document: SketchDocument(objects: [stroke(0, 0)]))
    let e = EraserController(model: m)
    e.begin(at: Vec2(x: 50, y: 50), radius: 1)
    e.move(to: Vec2(x: 60, y: 60))
    e.end()
    #expect(m.document.objects.count == 1)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func sweptSegmentHitsObjectBetweenSamples() {
    // One jump from x=-50 to x=50 across a short stroke at x=0: no sample point is near it.
    let target = stroke(-1, 0, length: 2)
    let m = DocumentModel(document: SketchDocument(objects: [target]))
    let e = EraserController(model: m)
    e.begin(at: Vec2(x: -50, y: 0), radius: 1)
    e.move(to: Vec2(x: 50, y: 0))
    #expect(e.hit == [target.id])
    e.end()
    #expect(m.document.objects.isEmpty)
}

@Test @MainActor func hitObjectsAreReportedHiddenAndCancelRestores() {
    let a = stroke(0, 0)
    let m = DocumentModel(document: SketchDocument(objects: [a]))
    let e = EraserController(model: m)
    var hidden: Set<ObjectID> = []
    e.onHiddenChange = { hidden = $0 }
    e.begin(at: Vec2(x: 1, y: 0), radius: 1)
    #expect(hidden == [a.id])
    #expect(m.document.objects.count == 1) // not removed yet
    e.cancel()
    #expect(hidden.isEmpty)
    e.end()
    #expect(m.document.objects == [a])
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func eraserRadiusIsConstantOnScreen() {
    let r1 = EraserController.worldRadius(zoom: 1)
    let r4 = EraserController.worldRadius(zoom: 4)
    #expect(abs(r1 * Viewport.pointsPerMillimetre - 8) < 1e-9)
    #expect(abs(r4 * 4 - r1) < 1e-9)
}
