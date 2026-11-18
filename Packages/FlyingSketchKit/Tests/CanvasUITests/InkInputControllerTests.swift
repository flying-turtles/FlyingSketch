import Testing
import SketchCore
import InkEngine
@testable import CanvasUI

private func sample(_ x: Double, _ y: Double, t: Double = 0) -> InkSample {
    InkSample(position: Vec2(x: x, y: y), force: 0.5, timestamp: t)
}

@MainActor private func onlyStroke(_ m: DocumentModel) -> InkStroke? {
    guard m.document.objects.count == 1, case .ink(let s) = m.document.objects[0] else { return nil }
    return s
}

@Test @MainActor func completedStrokeIsOneUndoableInsert() {
    let m = DocumentModel(document: .empty); let c = InkInputController(model: m)
    c.begin(sample(0, 0), tool: .pen, color: .black, width: 0.5)
    _ = c.move(coalesced: [sample(1, 0), sample(2, 1)], predicted: [])
    c.end()
    #expect(m.document.objects.count == 1)
    m.undoManager.undo(); #expect(m.document.objects.isEmpty)
}

@Test @MainActor func cancelledStrokeCommitsNothing() {
    let m = DocumentModel(document: .empty); let c = InkInputController(model: m)
    c.begin(sample(0, 0), tool: .pen, color: .black, width: 0.5)
    _ = c.move(coalesced: [sample(5, 5)], predicted: [])
    c.cancel()
    c.end()
    #expect(m.document.objects.isEmpty); #expect(!m.undoManager.canUndo)
}

@Test @MainActor func predictedSamplesNotCommitted() {
    let m = DocumentModel(document: .empty); let c = InkInputController(model: m)
    c.begin(sample(0, 0), tool: .pen, color: .black, width: 0.5)
    let live = c.move(coalesced: [sample(1, 0)], predicted: [sample(2, 0), sample(3, 0), sample(4, 0)])
    #expect(live.count == 5)
    c.end()
    #expect(onlyStroke(m)?.points.count == 2)
}

@Test @MainActor func strokeStoresToolStateInWorldUnits() {
    let m = DocumentModel(document: .empty); let c = InkInputController(model: m)
    let red = RGBAColor(r: 1, g: 0, b: 0)
    c.begin(sample(0, 0), tool: .marker, color: red, width: 0.5)
    _ = c.move(coalesced: [sample(1, 1)], predicted: [])
    c.end()
    let s = onlyStroke(m)
    #expect(s?.baseWidth == 0.5); #expect(s?.tool == .marker); #expect(s?.color == red)
}

@Test @MainActor func endWithoutBeginPerformsNothing() {
    let m = DocumentModel(document: .empty); let c = InkInputController(model: m)
    c.end()
    #expect(!m.undoManager.canUndo)
}

@Test @MainActor func startPointStoredOnce() {
    let m = DocumentModel(document: .empty); let c = InkInputController(model: m)
    c.begin(sample(0, 0), tool: .pen, color: .black, width: 0.5)
    let live = c.move(coalesced: [], predicted: [])
    #expect(live.count == 1)
    _ = c.move(coalesced: [sample(1, 0)], predicted: [])
    c.end()
    #expect(onlyStroke(m)?.points.map(\.position) == [Vec2(x: 0, y: 0), Vec2(x: 1, y: 0)])
}
