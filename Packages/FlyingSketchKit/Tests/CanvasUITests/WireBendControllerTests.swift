import Testing
import SketchCore
@testable import CanvasUI

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

@MainActor private func scene() -> (DocumentModel, Wire, WireBendController) {
    let w = Wire(start: WireEnd(position: v(0, 0), attachment: .connector(part: ObjectID.new(), connector: "a")),
                 end: WireEnd(position: v(10, 10)), bends: [v(10, 0)])
    let m = DocumentModel(document: SketchDocument(objects: [.wire(w)]))
    let c = WireBendController(model: m)
    c.minDistance = 0.5
    return (m, w, c)
}

@MainActor private func wire(_ m: DocumentModel) -> Wire {
    for case .wire(let w) in m.document.objects { return w }
    fatalError()
}

@Test @MainActor func dragBendCommitsMove() {
    let (m, w, c) = scene()
    #expect(c.begin(.bend(wire: w.id, index: 0), grabAt: v(10, 0)))
    #expect(c.move(to: v(14, 3))?.bends == [v(14, 3)])
    #expect(c.end(at: v(14, 3)))
    #expect(wire(m).bends == [v(14, 3)])
    #expect(m.undoManager.undoActionName == "Move Wire Bend")
    m.undoManager.undo()
    #expect(wire(m).bends == [v(10, 0)])
}

@Test @MainActor func grabOffsetNoJump() {
    let (m, w, c) = scene()
    c.begin(.bend(wire: w.id, index: 0), grabAt: v(10.4, 0.2))
    c.end(at: v(12.4, 0.2))
    let b = wire(m).bends[0]
    #expect(abs(b.x - 12) < 1e-9 && abs(b.y) < 1e-9)
}

@Test @MainActor func tapBendRemoves() {
    let (m, w, c) = scene()
    c.begin(.bend(wire: w.id, index: 0), grabAt: v(10, 0))
    #expect(c.end(at: v(10.1, 0)))
    #expect(wire(m).bends == [])
    #expect(m.undoManager.undoActionName == "Remove Wire Bend")
}

@Test @MainActor func dragInsertAddsBend() {
    let (m, w, c) = scene()
    #expect(c.begin(.insert(wire: w.id, segment: 0), grabAt: v(5, 0)))
    #expect(c.move(to: v(5, -4))?.bends == [v(5, -4), v(10, 0)])
    #expect(c.end(at: v(5, -4)))
    #expect(wire(m).bends == [v(5, -4), v(10, 0)])
    #expect(m.undoManager.undoActionName == "Add Wire Bend")
}

@Test @MainActor func tapInsertNoEdit() {
    let (m, w, c) = scene()
    c.begin(.insert(wire: w.id, segment: 1), grabAt: v(10, 5))
    #expect(!c.end(at: v(10, 5)))
    #expect(!m.undoManager.canUndo)
    #expect(!c.isActive)
}

@Test @MainActor func snapsToGrid() {
    let (m, w, c) = scene()
    c.snapsToGrid = true
    c.begin(.bend(wire: w.id, index: 0), grabAt: v(10, 0))
    c.end(at: v(13.2, 4.1))
    #expect(wire(m).bends == [snap(v(13.2, 4.1), grid: ShapeController.gridSize)])
}

@Test @MainActor func releaseAtStartNoEdit() {
    let (m, w, c) = scene()
    c.snapsToGrid = true
    c.begin(.bend(wire: w.id, index: 0), grabAt: v(10, 0))
    c.move(to: v(18, 6))
    #expect(!c.end(at: v(10.6, 0))) // a drag, but snaps back onto (10, 0)
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func wireChangedUnderDragNoEdit() {
    let (m, w, c) = scene()
    c.begin(.bend(wire: w.id, index: 0), grabAt: v(10, 0))
    var other = w
    other.bends = [v(3, 3)]
    m.perform(.replace([.wire(other)]), actionName: "Other")
    #expect(!c.end(at: v(30, 30)))
    #expect(wire(m) == other)
}

@Test @MainActor func wireDeletedUnderDragNoEdit() {
    let (m, w, c) = scene()
    c.begin(.bend(wire: w.id, index: 0), grabAt: v(10, 0))
    m.perform(.remove([w.id]), actionName: "Delete")
    #expect(!c.end(at: v(30, 30)))
    #expect(m.document.objects.isEmpty)
}

@Test @MainActor func endsUntouched() {
    let (m, w, c) = scene()
    c.begin(.insert(wire: w.id, segment: 0), grabAt: v(5, 0))
    c.end(at: v(5, 8))
    #expect(wire(m).start == w.start)
    #expect(wire(m).end == w.end)
}

@Test @MainActor func cancelNoEdit() {
    let (m, w, c) = scene()
    c.begin(.bend(wire: w.id, index: 0), grabAt: v(10, 0))
    c.move(to: v(20, 20))
    c.cancel()
    #expect(!c.isActive)
    #expect(c.move(to: v(1, 1)) == nil)
    #expect(!c.end(at: v(20, 20)))
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func beginOnMissingHandleFails() {
    let (_, w, c) = scene()
    #expect(!c.begin(.bend(wire: w.id, index: 1), grabAt: .zero))
    #expect(!c.begin(.insert(wire: w.id, segment: 2), grabAt: .zero))
    #expect(!c.begin(.bend(wire: ObjectID.new(), index: 0), grabAt: .zero))
    #expect(!c.isActive)
}
