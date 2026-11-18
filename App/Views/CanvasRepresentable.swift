import SwiftUI
import SketchCore
import CanvasUI

/// Hosts `CanvasView`; pushes SwiftUI tool state into it on every update.
struct CanvasRepresentable: UIViewRepresentable {
    let model: DocumentModel
    var toolState: ToolState
    var showsGrid: Bool
    var snapsToGrid: Bool
    var onCanvas: (CanvasView) -> Void
    var onPencilDoubleTap: () -> Void

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(model: model)
        view.onPencilDoubleTap = onPencilDoubleTap
        onCanvas(view)
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        view.toolState = toolState
        view.showsGrid = showsGrid
        view.snapsToGrid = snapsToGrid
        view.onPencilDoubleTap = onPencilDoubleTap
    }
}
