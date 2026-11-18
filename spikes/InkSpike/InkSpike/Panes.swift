import PencilKit
import SwiftUI

struct InkCanvasRepresentable: UIViewRepresentable {
    let renderer: ActiveStrokeRenderer
    let settings: InkSettings
    let clearToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InkCanvasView {
        InkCanvasView(renderer: renderer, settings: settings)
    }

    func updateUIView(_ view: InkCanvasView, context: Context) {
        if context.coordinator.clearToken != clearToken {
            context.coordinator.clearToken = clearToken
            view.clear()
        }
    }

    final class Coordinator { var clearToken = 0 }
}

struct PencilKitRepresentable: UIViewRepresentable {
    let width: Double
    let pencilOnly: Bool
    let clearToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = PKInkingTool(.pen, color: .black, width: width)
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        if context.coordinator.clearToken != clearToken {
            context.coordinator.clearToken = clearToken
            canvas.drawing = PKDrawing()
        }
    }

    final class Coordinator { var clearToken = 0 }
}
