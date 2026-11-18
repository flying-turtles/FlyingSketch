import SwiftUI
import SketchCore
import CanvasUI

/// SwiftUI-owned but unobserved reference to the live canvas.
final class CanvasHandle {
    weak var view: CanvasView?
}

/// Hosts `CanvasView`; pushes SwiftUI tool state into it on every update.
struct CanvasRepresentable: UIViewRepresentable {
    let model: DocumentModel
    var toolState: ToolState
    var showsGrid: Bool
    var snapsToGrid: Bool
    let handle: CanvasHandle
    var onPencilDoubleTap: () -> Void

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(model: model)
        view.onPencilDoubleTap = onPencilDoubleTap
        handle.view = view // plain reference, not SwiftUI state: no mutation during a view update
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        view.toolState = toolState
        view.showsGrid = showsGrid
        view.snapsToGrid = snapsToGrid
        view.onPencilDoubleTap = onPencilDoubleTap
    }
}
