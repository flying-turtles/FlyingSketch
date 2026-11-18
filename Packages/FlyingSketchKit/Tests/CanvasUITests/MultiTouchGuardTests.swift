import Testing
import SketchCore
@testable import CanvasUI

@Test @MainActor func fingersNeverCancelActivePencil() {
    #expect(!CanvasView.shouldCancelForMultiTouch(activeIsPencil: true, newTouchIsPencil: false, directTouchCount: 2))
    #expect(!CanvasView.shouldCancelForMultiTouch(activeIsPencil: true, newTouchIsPencil: false, directTouchCount: 5))
}

@Test @MainActor func newPencilNeverBlockedByRestingFingers() {
    #expect(!CanvasView.shouldCancelForMultiTouch(activeIsPencil: false, newTouchIsPencil: true, directTouchCount: 3))
    #expect(!CanvasView.shouldCancelForMultiTouch(activeIsPencil: nil, newTouchIsPencil: true, directTouchCount: 2))
}

@Test @MainActor func twoFingersCancelFingerInteraction() {
    #expect(CanvasView.shouldCancelForMultiTouch(activeIsPencil: false, newTouchIsPencil: false, directTouchCount: 2))
    #expect(CanvasView.shouldCancelForMultiTouch(activeIsPencil: nil, newTouchIsPencil: false, directTouchCount: 2))
    #expect(!CanvasView.shouldCancelForMultiTouch(activeIsPencil: false, newTouchIsPencil: false, directTouchCount: 1))
}

@Test @MainActor func pencilPreemptsActiveFingerOnly() {
    #expect(CanvasView.pencilPreemptsFinger(activeIsPencil: false, newTouchIsPencil: true))
    #expect(!CanvasView.pencilPreemptsFinger(activeIsPencil: true, newTouchIsPencil: true))
    #expect(!CanvasView.pencilPreemptsFinger(activeIsPencil: nil, newTouchIsPencil: true))
    #expect(!CanvasView.pencilPreemptsFinger(activeIsPencil: false, newTouchIsPencil: false))
}

@Test @MainActor func onlySwitchActionsToggleEraser() {
    #expect(CanvasView.togglesEraser(for: .switchEraser))
    #expect(CanvasView.togglesEraser(for: .switchPrevious))
    #expect(!CanvasView.togglesEraser(for: .ignore))
    #expect(!CanvasView.togglesEraser(for: .showColorPalette))
    #expect(!CanvasView.togglesEraser(for: .showInkAttributes))
}

@Test @MainActor func undoRedoTapsIgnoredDuringSingleTouchInteraction() {
    let stroke = SceneObject.ink(InkStroke(points: [InkPoint(position: .zero, pressure: 0.5, time: 0)],
                                           tool: .pen, baseWidth: 0.5))
    let m = DocumentModel(document: .empty)
    let v = CanvasView(model: m)
    m.perform(.insert([stroke], at: nil), actionName: "Draw")
    let busy: [CanvasView.Interaction] = [.ink, .erase, .lasso, .move, .shape, .wire, .wireEnd,
                                          .leg(ConnectorRef(part: stroke.id, connector: "a"))]
    for kind in busy {
        v.interaction = kind
        v.handleUndoTap()
        #expect(m.document.objects == [stroke], "\(kind)")
    }
    v.interaction = nil
    v.handleUndoTap()
    #expect(m.document.objects.isEmpty)
    for kind in busy {
        v.interaction = kind
        v.handleRedoTap()
        #expect(m.document.objects.isEmpty, "\(kind)")
    }
    v.interaction = nil
    v.handleRedoTap()
    #expect(m.document.objects == [stroke])
}
