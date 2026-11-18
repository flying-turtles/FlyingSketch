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
