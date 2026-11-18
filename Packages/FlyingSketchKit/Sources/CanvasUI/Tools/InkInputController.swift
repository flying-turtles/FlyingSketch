import SketchCore
import InkEngine

/// Turns a sequence of world-space samples into one undoable stroke insert. UIKit-free.
final class InkInputController {
    private let model: DocumentModel
    private var builder: StrokeBuilder?
    private var tool: InkTool = .pen
    private var color: RGBAColor = .black
    private var width: Double = 0.5

    init(model: DocumentModel) { self.model = model }

    var isActive: Bool { builder != nil }

    func begin(_ s: InkSample, tool: InkTool, color: RGBAColor, width: Double, params: InkParams = InkParams()) {
        self.tool = tool
        self.color = color
        self.width = width
        var b = StrokeBuilder(params: params)
        b.add(s)
        builder = b
    }

    /// Adds coalesced samples to the stroke; returns committed + predicted points for the live layer.
    func move(coalesced: [InkSample], predicted: [InkSample]) -> [InkPoint] {
        guard var b = builder else { return [] }
        for s in coalesced { b.add(s) }
        builder = b
        return b.points(predicted: predicted)
    }

    /// Commits one undoable insert. Never performs an empty edit.
    func end() {
        defer { builder = nil }
        guard let b = builder, !b.committed.isEmpty else { return }
        let stroke = InkStroke(points: b.committed, tool: tool, color: color, baseWidth: width)
        model.perform(.insert([.ink(stroke)], at: nil), actionName: "Draw")
    }

    func cancel() { builder = nil }
}
