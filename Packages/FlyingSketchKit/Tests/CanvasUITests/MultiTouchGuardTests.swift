import Testing
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
