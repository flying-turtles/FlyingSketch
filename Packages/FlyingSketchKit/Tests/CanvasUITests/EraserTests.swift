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

@Test @MainActor func sweptSegmentHitsObjectJustInsideRadiusBetweenSamples() {
    // Point-like stroke 0.99*radius from the segment, halfway between two samples (0.5 apart).
    let near = SceneObject.ink(InkStroke(points: [
        InkPoint(position: Vec2(x: 0.25, y: 0.99), pressure: 0.5, time: 0),
    ], tool: .pen, baseWidth: 0))
    let m = DocumentModel(document: SketchDocument(objects: [near]))
    let e = EraserController(model: m)
    e.begin(at: Vec2(x: -50, y: 0), radius: 1)
    e.move(to: Vec2(x: 50, y: 0))
    #expect(e.hit == [near.id])
}

@Test @MainActor func undoMidEraseDoesNotLeaveEmptyEntry() {
    let a = stroke(0, 0)
    let m = DocumentModel(document: SketchDocument(objects: [a]))
    m.perform(.remove([a.id]), actionName: "Other")
    let e = EraserController(model: m)
    m.undoManager.undo()
    e.begin(at: Vec2(x: 1, y: 0), radius: 1) // hits a
    m.perform(.remove([a.id]), actionName: "Other")
    m.undoManager.removeAllActions()
    e.end()
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func eraserSkipsPartsAndDetachesNothingWrongly() {
    // fixtureWithPartsAndWire: resistor at origin with a wire attached to its "b" leg.
    var doc = SketchDocument.fixtureWithPartsAndWire()
    let ink = stroke(-3, 0, length: 6) // drawn across the resistor body
    doc.objects.append(ink)
    let resistorID = doc.objects[0].id
    let kept = Wire(start: WireEnd(position: Vec2(x: -7, y: 3), attachment: .connector(part: resistorID, connector: "a")),
                    end: WireEnd(position: Vec2(x: -7, y: 30)))
    doc.objects.append(.wire(kept))
    let partIDs = doc.objects.filter { if case .part = $0 { true } else { false } }.map(\.id)
    let m = DocumentModel(document: doc)
    let e = EraserController(model: m)
    e.begin(at: Vec2(x: -10, y: 0), radius: 1)
    e.move(to: Vec2(x: 60, y: 0)) // sweeps over resistor, ink, wire start and board
    #expect(!e.hit.contains { partIDs.contains($0) })
    #expect(e.hit.contains(ink.id))
    e.end()
    let left = m.document.objects.map(\.id)
    #expect(partIDs.allSatisfy(left.contains))
    #expect(!left.contains(ink.id))
    // The swept wire is erased; the untouched wire on the resistor keeps its attachment.
    var wires: [Wire] = []
    for case .wire(let w) in m.document.objects { wires.append(w) }
    #expect(wires == [kept])
    m.undoManager.undo()
    #expect(m.document == doc)
}
